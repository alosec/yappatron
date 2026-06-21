import Foundation
import AVFoundation

/// OpenAI Realtime transcription provider using gpt-realtime-whisper.
/// Yappatron captures 16 kHz Float32 PCM; the Realtime transcription session
/// expects 24 kHz mono 16-bit little-endian PCM, so buffers are resampled here.
class OpenAIRealtimeSTTProvider: STTProvider, @unchecked Sendable {
    private static let transcriptionModel = "gpt-realtime-whisper"
    private static let diarizationModel = "gpt-4o-transcribe-diarize"
    private static let inputSampleRate = 24_000.0
    private static let diarizationRequestTimeout: TimeInterval = 8.0
    private static let minimumDiarizationDurationSec = 0.75

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionDelegate: OpenAIRealtimeWebSocketDelegate?
    private let apiKey: String
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?

    private var currentItemID: String?
    private var itemTranscripts: [String: String] = [:]
    private var currentUtterance = ""
    private var hasBufferedAudio = false
    private var hasDetectedSpeech = false
    private var isCommitInFlight = false
    private var streamAudioCursorSec = 0.0
    private var currentCommitAudio = Data()
    private var currentCommitStartSec: Double?
    private var pendingCommitAudio: [BufferedCommitAudio] = []
    private var committedAudioByItemID: [String: BufferedCommitAudio] = [:]

    private var eouTimer: Task<Void, Never>?
    private var silenceCommitTask: Task<Void, Never>?
    private var finalizeContinuation: CheckedContinuation<String?, Never>?
    private let finalizeLock = NSLock()
    private var finalizeTimeoutTask: Task<Void, Never>?
    private var sessionReadyContinuation: CheckedContinuation<Bool, Never>?
    private let sessionReadyLock = NSLock()
    private var isSessionConfigured = false
    private let eouDebounceMs: UInt64 = 1500
    private let speechRMSFloor: Float = 0.0045
    private var lastError: String?

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private struct BufferedCommitAudio {
        let pcm16Data: Data
        let sampleRate: Int
        let startSec: Double

        var durationSec: Double {
            let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
            return Double(sampleCount) / Double(sampleRate)
        }
    }

    func start() async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not set"])
        }

        streamAudioCursorSec = 0
        currentCommitAudio = Data()
        currentCommitStartSec = nil
        pendingCommitAudio = []
        committedAudioByItemID = [:]

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription")
        ]

        guard let url = components.url else {
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI Realtime URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        sessionDelegate = OpenAIRealtimeWebSocketDelegate()
        session = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()

        let opened = await sessionDelegate!.waitForOpen(timeout: 10.0)
        if !opened {
            let errorMsg = sessionDelegate?.lastError ?? "Connection timed out"
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI Realtime: \(errorMsg)"])
        }

        startReceiving()
        try await configureTranscriptionSession()

        let sessionReady = await waitForSessionReady(timeout: 10.0)
        if !sessionReady {
            let errorMsg = lastError ?? "Session update timed out"
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to configure OpenAI Realtime transcription: \(errorMsg)"])
        }

        isConnected = true
        log("OpenAIRealtimeSTTProvider: WebSocket opened and transcription session configured")
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard isConnected, let ws = webSocketTask else { return }

        let pcmData = resampleToPCM16Data(buffer)
        guard !pcmData.isEmpty else { return }

        let base64Audio = pcmData.base64EncodedString()
        let message = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(base64Audio)\"}"
        try await ws.send(.string(message))
        appendBufferedAudioForDiarization(pcmData)
        hasBufferedAudio = true
        updateLocalCommitState(from: buffer)
    }

    func finishCurrentUtterance() async throws -> String? {
        eouTimer?.cancel()
        eouTimer = nil

        guard hasBufferedAudio || !currentUtterance.isEmpty else {
            return takePendingUtterance()
        }

        return await withCheckedContinuation { continuation in
            let previousContinuation = finalizeLock.withLock {
                let previous = finalizeContinuation
                finalizeContinuation = continuation
                return previous
            }
            previousContinuation?.resume(returning: takePendingUtterance())

            finalizeTimeoutTask?.cancel()
            let timeoutNanoseconds: UInt64 = SpeakerLabelMap.enabled ? 9_000_000_000 : 2_500_000_000
            finalizeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.completeFinalize()
            }

            Task { [weak self] in
                do {
                    try await self?.commitCurrentBuffer()
                } catch {
                    log("OpenAIRealtimeSTTProvider: Commit send failed: \(error.localizedDescription)")
                    self?.completeFinalize()
                }
            }
        }
    }

    func finish() async throws -> String? {
        try await finishCurrentUtterance()
    }

    func reset() async {
        currentItemID = nil
        itemTranscripts = [:]
        currentUtterance = ""
        hasDetectedSpeech = false
        eouTimer?.cancel()
        eouTimer = nil
        silenceCommitTask?.cancel()
        silenceCommitTask = nil
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        let continuation = finalizeLock.withLock {
            let current = finalizeContinuation
            finalizeContinuation = nil
            return current
        }
        continuation?.resume(returning: nil)
    }

    func cleanup() {
        isConnected = false
        receiveTask?.cancel()
        eouTimer?.cancel()
        silenceCommitTask?.cancel()
        finalizeTimeoutTask?.cancel()
        let finalizeContinuation = finalizeLock.withLock {
            let current = self.finalizeContinuation
            self.finalizeContinuation = nil
            return current
        }
        finalizeContinuation?.resume(returning: nil)
        let sessionReadyContinuation = sessionReadyLock.withLock {
            let current = self.sessionReadyContinuation
            self.sessionReadyContinuation = nil
            isSessionConfigured = false
            return current
        }
        sessionReadyContinuation?.resume(returning: false)
        currentCommitAudio = Data()
        currentCommitStartSec = nil
        pendingCommitAudio = []
        committedAudioByItemID = [:]
        streamAudioCursorSec = 0
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        log("OpenAIRealtimeSTTProvider: Cleaned up")
    }

    // MARK: - Session Configuration

    private func configureTranscriptionSession() async throws {
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.inputSampleRate)
                        ],
                        "transcription": [
                            "model": Self.transcriptionModel,
                            "language": "en",
                            "delay": "low"
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]

        try await sendJSON(event)
    }

    private func waitForSessionReady(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = sessionReadyLock.withLock {
                if isSessionConfigured {
                    return true
                }

                self.sessionReadyContinuation = continuation
                return false
            }

            if shouldResumeImmediately {
                continuation.resume(returning: true)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                let continuation = self?.sessionReadyLock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard let continuation = self?.sessionReadyContinuation else { return nil }
                    self?.sessionReadyContinuation = nil
                    return continuation
                }
                continuation?.resume(returning: false)
            }
        }
    }

    private func markSessionReady(_ ready: Bool) {
        let continuation = sessionReadyLock.withLock {
            isSessionConfigured = ready
            let current = sessionReadyContinuation
            sessionReadyContinuation = nil
            return current
        }
        continuation?.resume(returning: ready)
    }

    // MARK: - WebSocket Send/Receive

    private func sendJSON(_ event: [String: Any]) async throws {
        guard let ws = webSocketTask else { return }
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode OpenAI Realtime event"])
        }

        try await ws.send(.string(text))
    }

    private func commitCurrentBuffer() async throws {
        guard isConnected, hasBufferedAudio, !isCommitInFlight else { return }

        isCommitInFlight = true
        hasBufferedAudio = false
        hasDetectedSpeech = false
        silenceCommitTask?.cancel()
        silenceCommitTask = nil

        let committedAudio = takeBufferedAudioForCommit()

        do {
            try await sendJSON([
                "type": "input_audio_buffer.commit",
                "event_id": "commit_\(UUID().uuidString)"
            ])

            if let committedAudio {
                pendingCommitAudio.append(committedAudio)
            }
        } catch {
            restoreBufferedAudioForCommit(committedAudio)
            throw error
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let ws = self.webSocketTask else { break }

                do {
                    let message = try await ws.receive()

                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        log("OpenAIRealtimeSTTProvider: Receive error: \(error.localizedDescription)")
                        self.isConnected = false
                        self.lastError = error.localizedDescription
                        self.markSessionReady(false)
                        self.completeFinalize()
                    }
                    break
                }
            }
        }
    }

    // MARK: - Message Parsing

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("OpenAIRealtimeSTTProvider: Unparseable message: \(text.prefix(200))")
            return
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "session.created":
            log("OpenAIRealtimeSTTProvider: Session created")
        case "session.updated", "transcription_session.updated":
            markSessionReady(true)
        case "input_audio_buffer.committed":
            isCommitInFlight = false
            if let itemID = json["item_id"] as? String {
                if currentItemID == nil {
                    currentItemID = itemID
                }
                if !pendingCommitAudio.isEmpty {
                    committedAudioByItemID[itemID] = pendingCommitAudio.removeFirst()
                }
            }
        case "conversation.item.input_audio_transcription.delta":
            handleTranscriptionDelta(json)
        case "conversation.item.input_audio_transcription.completed":
            handleTranscriptionCompleted(json)
        case "conversation.item.input_audio_transcription.failed":
            handleTranscriptionFailed(json)
        case "error":
            handleError(json)
        default:
            break
        }
    }

    private func handleTranscriptionDelta(_ json: [String: Any]) {
        guard let delta = json["delta"] as? String, !delta.isEmpty else { return }
        let itemID = json["item_id"] as? String ?? currentItemID ?? "current"

        currentItemID = itemID
        let transcript = (itemTranscripts[itemID] ?? "") + delta
        itemTranscripts[itemID] = transcript
        currentUtterance = transcript

        DispatchQueue.main.async { [weak self] in
            self?.onLockedTextAdvanced?(transcript.count)
            self?.onPartial?(transcript)
        }

        scheduleEOUTimer()
    }

    private func handleTranscriptionCompleted(_ json: [String: Any]) {
        isCommitInFlight = false
        let itemID = json["item_id"] as? String ?? currentItemID ?? "current"
        let transcript = json["transcript"] as? String
        let fallback = itemTranscripts[itemID] ?? currentUtterance
        let finalText = (transcript?.isEmpty == false ? transcript : fallback) ?? ""

        itemTranscripts.removeValue(forKey: itemID)
        if currentItemID == itemID {
            currentItemID = nil
        }
        currentUtterance = itemTranscripts[currentItemID ?? ""] ?? ""
        eouTimer?.cancel()
        eouTimer = nil

        let committedAudio = takeCommittedAudio(for: itemID)
        if hasFinalizeContinuation {
            Task { [weak self] in
                guard let self = self else { return }
                let runs = await self.diarizeCommittedAudio(committedAudio)
                guard self.hasFinalizeContinuation else { return }
                if !runs.isEmpty {
                    await MainActor.run {
                        self.onDiarizedFinal?(runs)
                    }
                }
                self.completeFinalize(with: finalText)
            }
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            let runs = await self.diarizeCommittedAudio(committedAudio)
            self.dispatchFinal(finalText, diarizedRuns: runs)
        }
    }

    private func handleTranscriptionFailed(_ json: [String: Any]) {
        isCommitInFlight = false
        let message = nestedErrorMessage(json) ?? "Transcription failed"
        log("OpenAIRealtimeSTTProvider: \(message)")
        completeFinalize()
    }

    private func handleError(_ json: [String: Any]) {
        isCommitInFlight = false
        let message = nestedErrorMessage(json) ?? "Unknown OpenAI Realtime error"
        lastError = message
        log("OpenAIRealtimeSTTProvider: Server error: \(message)")
        markSessionReady(false)
        completeFinalize()
    }

    private func nestedErrorMessage(_ json: [String: Any]) -> String? {
        guard let error = json["error"] as? [String: Any] else {
            return json["message"] as? String
        }

        let message = error["message"] as? String
        let code = error["code"] as? String
        if let message, let code {
            return "\(code): \(message)"
        }
        return message ?? code
    }

    // MARK: - Utterance Finalization

    private func scheduleEOUTimer() {
        eouTimer?.cancel()
        eouTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.eouDebounceMs ?? 3500) * 1_000_000)
            guard !Task.isCancelled, let self = self else { return }

            do {
                try await self.commitCurrentBuffer()
            } catch {
                log("OpenAIRealtimeSTTProvider: EOU commit failed: \(error.localizedDescription)")
                self.dispatchFinal(self.takePendingUtterance() ?? "")
            }
        }
    }

    private func updateLocalCommitState(from buffer: AVAudioPCMBuffer) {
        let rms = measuredRMS(from: buffer)

        if rms >= speechRMSFloor {
            hasDetectedSpeech = true
            silenceCommitTask?.cancel()
            silenceCommitTask = nil
            return
        }

        guard hasDetectedSpeech, hasBufferedAudio, silenceCommitTask == nil else { return }

        silenceCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.eouDebounceMs ?? 3500) * 1_000_000)
            guard !Task.isCancelled, let self = self else { return }
            do {
                try await self.commitCurrentBuffer()
            } catch {
                log("OpenAIRealtimeSTTProvider: Silence commit failed: \(error.localizedDescription)")
                self.completeFinalize()
            }
        }
    }

    private func dispatchFinal(
        _ text: String,
        diarizedRuns: [(speakerId: Int, text: String, startSec: Double, endSec: Double)] = []
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            if !diarizedRuns.isEmpty {
                self?.onDiarizedFinal?(diarizedRuns)
            }
            self?.onLockedTextAdvanced?(trimmed.count)
            self?.onPartial?(trimmed)
            self?.onFinal?(trimmed)
        }
    }

    private func takePendingUtterance() -> String? {
        let pending = currentUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        currentItemID = nil
        itemTranscripts = [:]
        currentUtterance = ""
        hasDetectedSpeech = false
        eouTimer?.cancel()
        eouTimer = nil
        silenceCommitTask?.cancel()
        silenceCommitTask = nil
        return pending.isEmpty ? nil : pending
    }

    private func completeFinalize(with text: String? = nil) {
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil

        let continuation = finalizeLock.withLock {
            let current = finalizeContinuation
            finalizeContinuation = nil
            return current
        }
        guard let continuation else { return }

        let finalText = text ?? takePendingUtterance()
        if text != nil {
            _ = takePendingUtterance()
        }
        continuation.resume(returning: finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? finalText : nil)
    }

    private var hasFinalizeContinuation: Bool {
        finalizeLock.withLock {
            finalizeContinuation != nil
        }
    }

    // MARK: - Diarization Fallback

    private func appendBufferedAudioForDiarization(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        if currentCommitAudio.isEmpty {
            currentCommitStartSec = streamAudioCursorSec
        }

        currentCommitAudio.append(pcmData)
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        streamAudioCursorSec += Double(sampleCount) / Self.inputSampleRate
    }

    private func takeBufferedAudioForCommit() -> BufferedCommitAudio? {
        guard !currentCommitAudio.isEmpty else { return nil }

        let audio = BufferedCommitAudio(
            pcm16Data: currentCommitAudio,
            sampleRate: Int(Self.inputSampleRate),
            startSec: currentCommitStartSec ?? max(0, streamAudioCursorSec)
        )

        currentCommitAudio = Data()
        currentCommitStartSec = nil
        return audio
    }

    private func restoreBufferedAudioForCommit(_ audio: BufferedCommitAudio?) {
        guard let audio else { return }

        if currentCommitAudio.isEmpty {
            currentCommitAudio = audio.pcm16Data
            currentCommitStartSec = audio.startSec
        } else {
            var restored = audio.pcm16Data
            restored.append(currentCommitAudio)
            currentCommitAudio = restored
            currentCommitStartSec = audio.startSec
        }
        hasBufferedAudio = true
    }

    private func takeCommittedAudio(for itemID: String?) -> BufferedCommitAudio? {
        if let itemID, let audio = committedAudioByItemID.removeValue(forKey: itemID) {
            return audio
        }

        if !pendingCommitAudio.isEmpty {
            return pendingCommitAudio.removeFirst()
        }

        return nil
    }

    private func diarizeCommittedAudio(
        _ audio: BufferedCommitAudio?
    ) async -> [(speakerId: Int, text: String, startSec: Double, endSec: Double)] {
        guard let audio,
              onDiarizedFinal != nil,
              SpeakerLabelMap.enabled,
              audio.durationSec >= Self.minimumDiarizationDurationSec else {
            return []
        }

        do {
            let wavData = Self.wavData(fromPCM16: audio.pcm16Data, sampleRate: audio.sampleRate)
            let request = try makeDiarizationRequest(wavData: wavData)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                log("OpenAIRealtimeSTTProvider: Diarization failed without HTTP response")
                return []
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                log("OpenAIRealtimeSTTProvider: Diarization HTTP \(http.statusCode): \(body.prefix(500))")
                return []
            }

            let runs = parseDiarizationResponse(data, baseStartSec: audio.startSec)
            if runs.isEmpty {
                log("OpenAIRealtimeSTTProvider: Diarization returned no speaker segments")
            }
            return runs
        } catch {
            log("OpenAIRealtimeSTTProvider: Diarization failed: \(error.localizedDescription)")
            return []
        }
    }

    private func makeDiarizationRequest(wavData: Data) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI transcription URL"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: Self.diarizationRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        Self.appendMultipartField(name: "model", value: Self.diarizationModel, boundary: boundary, to: &body)
        Self.appendMultipartField(name: "response_format", value: "diarized_json", boundary: boundary, to: &body)
        Self.appendMultipartField(name: "chunking_strategy", value: "auto", boundary: boundary, to: &body)
        Self.appendMultipartField(name: "language", value: "en", boundary: boundary, to: &body)
        Self.appendMultipartFile(
            name: "file",
            filename: "yappatron-utterance.wav",
            contentType: "audio/wav",
            data: wavData,
            boundary: boundary,
            to: &body
        )
        Self.appendUTF8("--\(boundary)--\r\n", to: &body)

        request.httpBody = body
        return request
    }

    private func parseDiarizationResponse(
        _ data: Data,
        baseStartSec: Double
    ) -> [(speakerId: Int, text: String, startSec: Double, endSec: Double)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]] else {
            return []
        }

        var speakerIDsByRawValue: [String: Int] = [:]
        var runs: [(speakerId: Int, text: String, startSec: Double, endSec: Double)] = []

        for segment in segments {
            let text = (segment["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let speakerId = speakerID(from: segment["speaker"], mapping: &speakerIDsByRawValue)
            let start = Self.doubleValue(segment["start"]) ?? 0
            let end = Self.doubleValue(segment["end"]) ?? start
            let runStart = baseStartSec + max(0, start)
            let runEnd = baseStartSec + max(start, end)

            if var last = runs.last, last.speakerId == speakerId {
                last.text += " " + text
                last.endSec = max(last.endSec, runEnd)
                runs[runs.count - 1] = last
            } else {
                runs.append((speakerId: speakerId, text: text, startSec: runStart, endSec: runEnd))
            }
        }

        return runs
    }

    private func speakerID(from value: Any?, mapping: inout [String: Int]) -> Int {
        if let intValue = value as? Int {
            return intValue
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        guard let raw = value as? String, !raw.isEmpty else {
            return -1
        }

        if let existing = mapping[raw] {
            return existing
        }

        if let parsed = Self.trailingInteger(in: raw) {
            mapping[raw] = parsed
            return parsed
        }

        let next = mapping.values.max().map { $0 + 1 } ?? 0
        mapping[raw] = next
        return next
    }

    private static func trailingInteger(in value: String) -> Int? {
        let digits = value.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func appendMultipartField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        appendUTF8("--\(boundary)\r\n", to: &body)
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", to: &body)
        appendUTF8("\(value)\r\n", to: &body)
    }

    private static func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        appendUTF8("--\(boundary)\r\n", to: &body)
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n", to: &body)
        appendUTF8("Content-Type: \(contentType)\r\n\r\n", to: &body)
        body.append(data)
        appendUTF8("\r\n", to: &body)
    }

    private static func wavData(fromPCM16 pcmData: Data, sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * MemoryLayout<Int16>.size
        let blockAlign = MemoryLayout<Int16>.size

        appendUTF8("RIFF", to: &data)
        appendUInt32LE(UInt32(36 + pcmData.count), to: &data)
        appendUTF8("WAVE", to: &data)
        appendUTF8("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(byteRate), to: &data)
        appendUInt16LE(UInt16(blockAlign), to: &data)
        appendUInt16LE(16, to: &data)
        appendUTF8("data", to: &data)
        appendUInt32LE(UInt32(pcmData.count), to: &data)
        data.append(pcmData)

        return data
    }

    private static func appendUTF8(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    // MARK: - Audio Conversion

    private func resampleToPCM16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.floatChannelData else { return Data() }

        let inputCount = Int(buffer.frameLength)
        guard inputCount > 0 else { return Data() }

        let sourceRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 16_000.0
        let outputCount = max(1, Int((Double(inputCount) * Self.inputSampleRate / sourceRate).rounded()))
        let input = channelData[0]

        var data = Data(count: outputCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: Int16.self)

            if outputCount == 1 || inputCount == 1 {
                output[0] = Self.floatToInt16(input[0])
                return
            }

            let scale = Double(inputCount - 1) / Double(outputCount - 1)
            for outputIndex in 0..<outputCount {
                let sourcePosition = Double(outputIndex) * scale
                let lowerIndex = Int(sourcePosition)
                let upperIndex = min(lowerIndex + 1, inputCount - 1)
                let fraction = Float(sourcePosition - Double(lowerIndex))
                let sample = input[lowerIndex] + (input[upperIndex] - input[lowerIndex]) * fraction
                output[outputIndex] = Self.floatToInt16(sample)
            }
        }

        return data
    }

    private func measuredRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += samples[i] * samples[i]
        }

        return sqrt(sum / Float(frameLength))
    }

    private static func floatToInt16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        return Int16(clamped * 32767.0)
    }
}

// MARK: - WebSocket Delegate

private class OpenAIRealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private var openContinuation: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    var lastError: String?

    func waitForOpen(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.openContinuation = continuation
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                let continuation = self?.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard let continuation = self?.openContinuation else { return nil }
                    self?.openContinuation = nil
                    self?.lastError = "Connection timed out after \(timeout)s"
                    return continuation
                }
                continuation?.resume(returning: false)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        log("OpenAIRealtimeSTTProvider: WebSocket didOpen")
        let continuation = lock.withLock {
            let current = openContinuation
            openContinuation = nil
            return current
        }
        continuation?.resume(returning: true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        log("OpenAIRealtimeSTTProvider: WebSocket didClose code=\(closeCode.rawValue) reason=\(reasonStr)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }

        log("OpenAIRealtimeSTTProvider: Task error: \(error.localizedDescription)")
        if let httpResponse = task.response as? HTTPURLResponse {
            lastError = "HTTP \(httpResponse.statusCode)"
            log("OpenAIRealtimeSTTProvider: HTTP status: \(httpResponse.statusCode)")
        } else {
            lastError = error.localizedDescription
        }

        let continuation = lock.withLock {
            let current = openContinuation
            openContinuation = nil
            return current
        }
        continuation?.resume(returning: false)
    }
}
