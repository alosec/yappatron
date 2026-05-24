import Foundation
import AVFoundation

/// OpenAI Realtime transcription provider using gpt-realtime-whisper.
/// Yappatron captures 16 kHz Float32 PCM; the Realtime transcription session
/// expects 24 kHz mono 16-bit little-endian PCM, so buffers are resampled here.
class OpenAIRealtimeSTTProvider: STTProvider, @unchecked Sendable {
    private static let transcriptionModel = "gpt-realtime-whisper"
    private static let inputSampleRate = 24_000.0

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

    private var eouTimer: Task<Void, Never>?
    private var silenceCommitTask: Task<Void, Never>?
    private var finalizeContinuation: CheckedContinuation<String?, Never>?
    private var finalizeTimeoutTask: Task<Void, Never>?
    private var sessionReadyContinuation: CheckedContinuation<Bool, Never>?
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

    func start() async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "OpenAIRealtimeSTTProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not set"])
        }

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
            finalizeContinuation?.resume(returning: takePendingUtterance())
            finalizeContinuation = continuation

            finalizeTimeoutTask?.cancel()
            finalizeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
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
        finalizeContinuation?.resume(returning: nil)
        finalizeContinuation = nil
    }

    func cleanup() {
        isConnected = false
        receiveTask?.cancel()
        eouTimer?.cancel()
        silenceCommitTask?.cancel()
        finalizeTimeoutTask?.cancel()
        finalizeContinuation?.resume(returning: nil)
        finalizeContinuation = nil
        sessionReadyContinuation?.resume(returning: false)
        sessionReadyContinuation = nil
        isSessionConfigured = false
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
            if isSessionConfigured {
                continuation.resume(returning: true)
                return
            }

            self.sessionReadyContinuation = continuation

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let continuation = self?.sessionReadyContinuation {
                    self?.sessionReadyContinuation = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func markSessionReady(_ ready: Bool) {
        isSessionConfigured = ready
        sessionReadyContinuation?.resume(returning: ready)
        sessionReadyContinuation = nil
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

        try await sendJSON([
            "type": "input_audio_buffer.commit",
            "event_id": "commit_\(UUID().uuidString)"
        ])
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
            if let itemID = json["item_id"] as? String, currentItemID == nil {
                currentItemID = itemID
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

        if finalizeContinuation != nil {
            completeFinalize(with: finalText)
            return
        }

        dispatchFinal(finalText)
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

    private func dispatchFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
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

        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil

        let finalText = text ?? takePendingUtterance()
        if text != nil {
            _ = takePendingUtterance()
        }
        continuation.resume(returning: finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? finalText : nil)
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
    var lastError: String?

    func waitForOpen(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.openContinuation = continuation

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let continuation = self?.openContinuation {
                    self?.openContinuation = nil
                    self?.lastError = "Connection timed out after \(timeout)s"
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        log("OpenAIRealtimeSTTProvider: WebSocket didOpen")
        openContinuation?.resume(returning: true)
        openContinuation = nil
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

        openContinuation?.resume(returning: false)
        openContinuation = nil
    }
}
