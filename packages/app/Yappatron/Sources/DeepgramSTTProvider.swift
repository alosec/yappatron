import Foundation
import AVFoundation

/// Deepgram real-time streaming STT provider via WebSocket
/// Uses Nova-3 model with punctuation, sub-300ms latency
class DeepgramSTTProvider: STTProvider, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionDelegate: WebSocketDelegate?
    private let apiKey: String
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    // EOU detection
    private var currentUtterance = ""      // Accumulated is_final text
    private var lastInterimText = ""       // Last interim shown (for safe replacement)
    private var lastEmittedPartial = ""    // Last text sent to onPartial (for append-only check)
    /// Accumulated speaker-tagged runs across is_final segments within the current utterance.
    /// Consecutive entries with the same speakerId are merged.
    private var currentDiarizedRuns: [(speakerId: Int, text: String)] = []
    /// Per-run audio time bounds (seconds since stream open), parallel to currentDiarizedRuns.
    /// Used by the engine to slice audio for embedding-based override.
    private var currentRunTimings: [(startSec: Double, endSec: Double)] = []
    private var eouTimer: Task<Void, Never>?
    private var finalizeContinuation: CheckedContinuation<String?, Never>?
    private var finalizeTimeoutTask: Task<Void, Never>?
    private let eouDebounceMs: UInt64 = 800

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func start() async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "DeepgramSTTProvider", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Deepgram API key not set"])
        }

        // Build WebSocket URL with all params including auth
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "endpointing", value: "650"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
        ]

        guard let url = components.url else {
            throw NSError(domain: "DeepgramSTTProvider", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid Deepgram URL"])
        }

        // Use URLRequest with Authorization header
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        // Create delegate to track WebSocket lifecycle
        sessionDelegate = WebSocketDelegate()
        session = URLSession(
            configuration: .default,
            delegate: sessionDelegate,
            delegateQueue: nil
        )

        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Wait for the delegate to confirm WebSocket opened
        let opened = await sessionDelegate!.waitForOpen(timeout: 10.0)
        if !opened {
            let errorMsg = sessionDelegate?.lastError ?? "Connection timed out"
            throw NSError(domain: "DeepgramSTTProvider", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Deepgram: \(errorMsg)"])
        }

        isConnected = true
        log("DeepgramSTTProvider: WebSocket opened successfully")

        // Start receiving messages
        startReceiving()
        startKeepAlive()
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard isConnected, let ws = webSocketTask else { return }

        // Convert AVAudioPCMBuffer to Int16 PCM bytes (linear16)
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let floatPointer = channelData[0]

        // Convert Float32 [-1.0, 1.0] to Int16 [-32768, 32767]
        var data = Data(count: frameLength * 2)
        data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameLength {
                let clamped = max(-1.0, min(1.0, floatPointer[i]))
                int16Buffer[i] = Int16(clamped * 32767.0)
            }
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        try await ws.send(message)
    }

    func finishCurrentUtterance() async throws -> String? {
        guard isConnected, let ws = webSocketTask else {
            return takePendingUtterance()
        }

        eouTimer?.cancel()
        eouTimer = nil

        return await withCheckedContinuation { continuation in
            finalizeContinuation?.resume(returning: takePendingUtterance())
            finalizeContinuation = continuation

            finalizeTimeoutTask?.cancel()
            finalizeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.completeFinalize()
            }

            Task { [weak self] in
                do {
                    try await ws.send(.string("{\"type\":\"Finalize\"}"))
                } catch {
                    log("DeepgramSTTProvider: Finalize send failed: \(error.localizedDescription)")
                    self?.completeFinalize()
                }
            }
        }
    }

    func finish() async throws -> String? {
        guard isConnected, let ws = webSocketTask else { return nil }

        // Send CloseStream message per Deepgram protocol
        let closeMessage = "{\"type\": \"CloseStream\"}"
        try await ws.send(.string(closeMessage))

        let pending = currentUtterance
        currentUtterance = ""
        currentDiarizedRuns = []
        currentRunTimings = []
        return pending.isEmpty ? nil : pending
    }

    func reset() async {
        currentUtterance = ""
        currentDiarizedRuns = []
        currentRunTimings = []
        lastInterimText = ""
        lastEmittedPartial = ""
        eouTimer?.cancel()
        eouTimer = nil
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        finalizeContinuation?.resume(returning: nil)
        finalizeContinuation = nil
    }

    func cleanup() {
        isConnected = false
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        eouTimer?.cancel()
        finalizeTimeoutTask?.cancel()
        finalizeContinuation?.resume(returning: nil)
        finalizeContinuation = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        log("DeepgramSTTProvider: Cleaned up")
    }

    // MARK: - WebSocket Receive Loop

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
                        log("DeepgramSTTProvider: Receive error: \(error.localizedDescription)")
                        self.isConnected = false
                    }
                    break
                }
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
                guard let self = self, self.isConnected, let ws = self.webSocketTask else { break }
                let keepAlive = "{\"type\": \"KeepAlive\"}"
                try? await ws.send(.string(keepAlive))
            }
        }
    }

    // MARK: - Message Parsing

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("DeepgramSTTProvider: Unparseable message: \(text.prefix(200))")
            return
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "Results":
            handleResults(json)
        case "UtteranceEnd":
            handleUtteranceEnd()
        case "Metadata":
            log("DeepgramSTTProvider: Connected, request_id=\(json["request_id"] ?? "?")")
        case "SpeechStarted":
            break
        case "Error":
            let message = json["message"] as? String ?? "Unknown error"
            log("DeepgramSTTProvider: Server error: \(message)")
        default:
            log("DeepgramSTTProvider: Unknown message type: \(type)")
        }
    }

    private func handleResults(_ json: [String: Any]) {
        guard let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let transcript = firstAlt["transcript"] as? String else {
            return
        }

        let isFinal = json["is_final"] as? Bool ?? false
        let fromFinalize = json["from_finalize"] as? Bool ?? false
        let speechFinal = json["speech_final"] as? Bool ?? false

        if transcript.isEmpty {
            if fromFinalize || finalizeContinuation != nil {
                completeFinalize()
            } else if speechFinal {
                emitCurrentUtterance(reason: "speech_final")
            }
            return
        }

        if isFinal {
            // Clear any interim text first, then show the locked final
            lastInterimText = ""

            if !currentUtterance.isEmpty {
                currentUtterance += " "
            }
            currentUtterance += transcript

            // Pull word-level speaker tags (present when diarize=true) and merge into runs.
            if let words = firstAlt["words"] as? [[String: Any]] {
                appendDiarizedRuns(from: words)
            }

            log("DeepgramSTTProvider: Final segment: '\(currentUtterance)'")
            let partial = currentUtterance
            let lockedLen = partial.count
            DispatchQueue.main.async { [weak self] in
                self?.onLockedTextAdvanced?(lockedLen)
                self?.onPartial?(partial)
            }

            if fromFinalize || finalizeContinuation != nil {
                completeFinalize()
            } else if speechFinal {
                emitCurrentUtterance(reason: "speech_final")
            } else {
                scheduleEOUTimer()
            }
        } else {
            // Send interims for speech detection (orb) — app uses lockedTextLength
            // to distinguish these from is_final segments and won't type them
            let fullText = currentUtterance.isEmpty ? transcript : "\(currentUtterance) \(transcript)"
            DispatchQueue.main.async { [weak self] in
                self?.onPartial?(fullText)
            }
            scheduleEOUTimer()
        }
    }

    private func handleUtteranceEnd() {
        emitCurrentUtterance(reason: "UtteranceEnd")
    }

    private func scheduleEOUTimer() {
        eouTimer?.cancel()
        eouTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.eouDebounceMs ?? 800) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self, !self.currentUtterance.isEmpty else { return }

            self.emitCurrentUtterance(reason: "EOU timer")
        }
    }

    private func emitCurrentUtterance(reason: String) {
        guard !currentUtterance.isEmpty else { return }

        let utterance = currentUtterance
        let runs = takeRunsWithTimings()
        currentUtterance = ""
        eouTimer?.cancel()
        eouTimer = nil

        log("DeepgramSTTProvider: \(reason): '\(utterance)' (\(runs.count) speaker runs)")
        if finalizeContinuation != nil {
            completeFinalize(with: utterance)
            return
        }

        DispatchQueue.main.async { [weak self] in
            if !runs.isEmpty {
                self?.onDiarizedFinal?(runs)
            }
            self?.onFinal?(utterance)
        }
    }

    /// Drain currentDiarizedRuns + currentRunTimings into a single tuple list and clear both.
    private func takeRunsWithTimings() -> [(speakerId: Int, text: String, startSec: Double, endSec: Double)] {
        let count = min(currentDiarizedRuns.count, currentRunTimings.count)
        var out: [(speakerId: Int, text: String, startSec: Double, endSec: Double)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let r = currentDiarizedRuns[i]
            let t = currentRunTimings[i]
            out.append((speakerId: r.speakerId, text: r.text, startSec: t.startSec, endSec: t.endSec))
        }
        currentDiarizedRuns = []
        currentRunTimings = []
        return out
    }

    /// Group word-level speaker tags from a Results frame into runs of the same speaker
    /// and append to `currentDiarizedRuns`, merging the boundary if the previous run
    /// already ended with the same speaker. Also collects per-run audio time bounds
    /// from the words' `start`/`end` fields (seconds since stream open).
    private func appendDiarizedRuns(from words: [[String: Any]]) {
        struct LocalRun { var speakerId: Int; var text: String; var startSec: Double; var endSec: Double }
        var localRuns: [LocalRun] = []
        for w in words {
            guard let punct = (w["punctuated_word"] as? String) ?? (w["word"] as? String),
                  !punct.isEmpty else { continue }
            let speakerId = w["speaker"] as? Int ?? 0
            let start = (w["start"] as? Double) ?? 0
            let end = (w["end"] as? Double) ?? start
            if var last = localRuns.last, last.speakerId == speakerId {
                last.text += " " + punct
                last.endSec = end
                localRuns[localRuns.count - 1] = last
            } else {
                localRuns.append(LocalRun(speakerId: speakerId, text: punct, startSec: start, endSec: end))
            }
        }
        guard !localRuns.isEmpty else { return }
        for run in localRuns {
            if var last = currentDiarizedRuns.last, last.speakerId == run.speakerId,
               var lastTiming = currentRunTimings.last {
                last.text += " " + run.text
                lastTiming.endSec = run.endSec
                currentDiarizedRuns[currentDiarizedRuns.count - 1] = last
                currentRunTimings[currentRunTimings.count - 1] = lastTiming
            } else {
                currentDiarizedRuns.append((speakerId: run.speakerId, text: run.text))
                currentRunTimings.append((startSec: run.startSec, endSec: run.endSec))
            }
        }
    }

    private func takePendingUtterance() -> String? {
        let pending = currentUtterance
        let pendingRuns = takeRunsWithTimings()
        currentUtterance = ""
        lastInterimText = ""
        lastEmittedPartial = ""
        eouTimer?.cancel()
        eouTimer = nil
        if !pendingRuns.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onDiarizedFinal?(pendingRuns)
            }
        }
        return pending.isEmpty ? nil : pending
    }

    private func completeFinalize(with utterance: String? = nil) {
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil

        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil

        if let utterance = utterance {
            lastInterimText = ""
            lastEmittedPartial = ""
            eouTimer?.cancel()
            eouTimer = nil
            continuation.resume(returning: utterance.isEmpty ? nil : utterance)
        } else {
            continuation.resume(returning: takePendingUtterance())
        }
    }
}

// MARK: - WebSocket Delegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private var openContinuation: CheckedContinuation<Bool, Never>?
    var lastError: String?

    func waitForOpen(timeout: TimeInterval) async -> Bool {
        return await withCheckedContinuation { continuation in
            self.openContinuation = continuation

            // Timeout fallback
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let cont = self?.openContinuation {
                    self?.openContinuation = nil
                    self?.lastError = "Connection timed out after \(timeout)s"
                    cont.resume(returning: false)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        log("DeepgramSTTProvider: WebSocket didOpen")
        openContinuation?.resume(returning: true)
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        log("DeepgramSTTProvider: WebSocket didClose code=\(closeCode.rawValue) reason=\(reasonStr)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            log("DeepgramSTTProvider: Task error: \(error.localizedDescription)")

            if let httpResponse = task.response as? HTTPURLResponse {
                lastError = "HTTP \(httpResponse.statusCode)"
                log("DeepgramSTTProvider: HTTP status: \(httpResponse.statusCode)")
                // Log dg-error header for Deepgram-specific error info
                if let dgError = httpResponse.allHeaderFields["dg-error"] as? String {
                    log("DeepgramSTTProvider: dg-error: \(dgError)")
                    lastError = "HTTP \(httpResponse.statusCode): \(dgError)"
                }
            } else {
                lastError = error.localizedDescription
            }

            // Try to read the response body from the error userInfo
            let nsError = error as NSError
            if let data = nsError.userInfo["NSErrorFailingURLStringKey"] {
                log("DeepgramSTTProvider: Failing URL: \(data)")
            }

            openContinuation?.resume(returning: false)
            openContinuation = nil
        }
    }
}
