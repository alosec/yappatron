import Foundation
import AVFoundation

/// Deepgram real-time streaming STT provider via WebSocket
/// Uses Nova-3 model with punctuation, sub-300ms latency
class DeepgramSTTProvider: STTProvider {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let apiKey: String
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    // EOU detection: Deepgram sends is_final=true on speech_final events
    // We also track silence for manual EOU fallback
    private var currentUtterance = ""
    private var eouTimer: Task<Void, Never>?
    private let eouDebounceMs: UInt64 = 800

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func start() async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "DeepgramSTTProvider", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Deepgram API key not set"])
        }

        // Build WebSocket URL with query params
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "utterance_end_ms", value: "800"),
            URLQueryItem(name: "vad_events", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "endpointing", value: "800"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        guard let url = components.url else {
            throw NSError(domain: "DeepgramSTTProvider", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid Deepgram URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        session = URLSession(configuration: .default)
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()

        isConnected = true
        log("DeepgramSTTProvider: WebSocket connected")

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

        // Return any pending utterance
        let pending = currentUtterance
        currentUtterance = ""
        return pending.isEmpty ? nil : pending
    }

    func reset() async {
        currentUtterance = ""
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
            // VAD detected speech start
            break
        case "Error":
            let message = json["message"] as? String ?? "Unknown error"
            log("DeepgramSTTProvider: Error: \(message)")
        default:
            break
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
            // Accumulate final segments within an utterance
            if !currentUtterance.isEmpty {
                currentUtterance += " "
            }
            currentUtterance += transcript

            if speechFinal {
                // End of utterance — Deepgram detected a natural pause
                let utterance = currentUtterance
                currentUtterance = ""
                eouTimer?.cancel()

                log("DeepgramSTTProvider: Final (speech_final): '\(utterance)'")
                DispatchQueue.main.async { [weak self] in
                    self?.onFinal?(utterance)
                }
            } else {
                // Final segment but speech continues — send as partial
                log("DeepgramSTTProvider: Final segment: '\(currentUtterance)'")
                let partial = currentUtterance
                DispatchQueue.main.async { [weak self] in
                    self?.onPartial?(partial)
                }

                // Start EOU timer in case no more speech comes
                scheduleEOUTimer()
            }
        } else {
            // Interim result — show as partial
            let partialText = currentUtterance.isEmpty ? transcript : "\(currentUtterance) \(transcript)"
            log("DeepgramSTTProvider: Partial: '\(partialText)'")
            DispatchQueue.main.async { [weak self] in
                self?.onPartial?(partialText)
            }

            // Reset EOU timer on new audio
            scheduleEOUTimer()
        }
    }

    private func handleUtteranceEnd() {
        // Deepgram's UtteranceEnd event — definitively marks end of speech
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
            try? await Task.sleep(nanoseconds: self?.eouDebounceMs ?? 800 * 1_000_000)
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
