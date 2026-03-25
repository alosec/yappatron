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
    private var eouTimer: Task<Void, Never>?
    private let eouDebounceMs: UInt64 = 2500

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?

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
            URLQueryItem(name: "endpointing", value: "1800"),
            URLQueryItem(name: "smart_format", value: "true"),
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

    func finish() async throws -> String? {
        guard isConnected, let ws = webSocketTask else { return nil }

        // Send CloseStream message per Deepgram protocol
        let closeMessage = "{\"type\": \"CloseStream\"}"
        try await ws.send(.string(closeMessage))

        let pending = currentUtterance
        currentUtterance = ""
        return pending.isEmpty ? nil : pending
    }

    func reset() async {
        currentUtterance = ""
        lastInterimText = ""
        lastEmittedPartial = ""
        eouTimer?.cancel()
        eouTimer = nil
    }

    func cleanup() {
        isConnected = false
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        eouTimer?.cancel()
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
        let speechFinal = json["speech_final"] as? Bool ?? false

        guard !transcript.isEmpty else { return }

        if isFinal {
            // Clear any interim text first, then show the locked final
            lastInterimText = ""

            if !currentUtterance.isEmpty {
                currentUtterance += " "
            }
            currentUtterance += transcript

            if false /* speechFinal disabled — let silence timeout handle EOU */ {
                let utterance = currentUtterance
                currentUtterance = ""
                eouTimer?.cancel()

                log("DeepgramSTTProvider: Final (speech_final): '\(utterance)'")
                DispatchQueue.main.async { [weak self] in
                    self?.onFinal?(utterance)
                }
            } else {
                log("DeepgramSTTProvider: Final segment: '\(currentUtterance)'")
                let partial = currentUtterance
                let lockedLen = partial.count
                DispatchQueue.main.async { [weak self] in
                    self?.onLockedTextAdvanced?(lockedLen)
                    self?.onPartial?(partial)
                }
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
        guard !currentUtterance.isEmpty else { return }

        let utterance = currentUtterance
        currentUtterance = ""
        eouTimer?.cancel()

        log("DeepgramSTTProvider: UtteranceEnd: '\(utterance)'")
        DispatchQueue.main.async { [weak self] in
            self?.onFinal?(utterance)
        }
    }

    private func scheduleEOUTimer() {
        eouTimer?.cancel()
        eouTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.eouDebounceMs ?? 800) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self, !self.currentUtterance.isEmpty else { return }

            let utterance = self.currentUtterance
            self.currentUtterance = ""

            log("DeepgramSTTProvider: EOU timer fired: '\(utterance)'")
            DispatchQueue.main.async { [weak self] in
                self?.onFinal?(utterance)
            }
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
