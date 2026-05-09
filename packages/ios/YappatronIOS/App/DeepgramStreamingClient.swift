import Foundation

final class DeepgramStreamingClient: NSObject {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case connectionFailed(String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Deepgram API key is required."
            case .invalidURL:
                return "Could not create the Deepgram streaming URL."
            case .connectionFailed(let reason):
                return "Deepgram connection failed: \(reason)"
            case .notConnected:
                return "Deepgram is not connected."
            }
        }
    }

    private struct Message: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                let transcript: String
                let words: [DiarizedWord]?
            }

            let alternatives: [Alternative]
        }

        let type: String?
        let channel: Channel?
        let start: Double?
        let duration: Double?
        let is_final: Bool?
        let from_finalize: Bool?
        let message: String?
    }

    var onTranscript: ((String, Bool) -> Void)?
    /// Called once per `is_final` turn with diarized runs aggregated from the
    /// word-level Deepgram payload. Empty array if Deepgram didn't return word
    /// data (e.g. diarize disabled or short interim).
    var onDiarizedFinal: (([DiarizedRun]) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private var session: URLSession?
    private var sessionDelegate: WebSocketDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private var finalSegments: [String] = []
    private var latestInterim = ""
    private var isConnected = false

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func connect() async throws {
        guard !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")
        components?.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "endpointing", value: "900")
        ]

        guard let url = components?.url else {
            throw ClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let delegate = WebSocketDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        self.sessionDelegate = delegate
        self.session = session
        self.webSocketTask = task

        task.resume()

        let opened = await delegate.waitForOpen(timeout: 10)
        guard opened else {
            throw ClientError.connectionFailed(delegate.lastError ?? "Timed out")
        }

        isConnected = true
        startReceiving()
        startKeepAlive()
    }

    func sendAudio(_ data: Data) async throws {
        guard isConnected, let webSocketTask else {
            throw ClientError.notConnected
        }

        try await webSocketTask.send(.data(data))
    }

    func finish() async throws -> String {
        guard isConnected, let webSocketTask else {
            return currentTranscript()
        }

        try? await webSocketTask.send(.string("{\"type\":\"Finalize\"}"))
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        return currentTranscript()
    }

    func disconnect() async {
        isConnected = false
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        receiveTask = nil
        keepAliveTask = nil

        if let webSocketTask {
            try? await webSocketTask.send(.string("{\"type\":\"CloseStream\"}"))
            webSocketTask.cancel(with: .goingAway, reason: nil)
        }

        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let webSocketTask = self.webSocketTask else {
                    break
                }

                do {
                    let message = try await webSocketTask.receive()
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
                    guard !Task.isCancelled else {
                        break
                    }

                    self.isConnected = false
                    let message = error.localizedDescription
                    let onError = self.onError
                    DispatchQueue.main.async {
                        onError?(message)
                    }
                    break
                }
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.isConnected, let webSocketTask = self.webSocketTask else {
                    break
                }

                try? await webSocketTask.send(.string("{\"type\":\"KeepAlive\"}"))
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Message.self, from: data) else {
            return
        }

        switch message.type {
        case "Results":
            handleResults(message)
        case "Error":
            DispatchQueue.main.async { [weak self] in
                self?.onError?(message.message ?? "Unknown Deepgram error.")
            }
        default:
            break
        }
    }

    private func handleResults(_ message: Message) {
        guard let alternative = message.channel?.alternatives.first,
              !alternative.transcript.isEmpty else {
            return
        }
        let transcript = alternative.transcript

        if message.is_final == true {
            latestInterim = ""
            finalSegments.append(transcript)

            // Diarized runs (one finalized turn → 1+ runs depending on whether
            // the speaker changed mid-turn). Surfaced through onDiarizedFinal
            // so the caller can post per-run if desired.
            if let words = alternative.words, !words.isEmpty {
                let runs = words.intoRuns()
                let onDiarized = self.onDiarizedFinal
                DispatchQueue.main.async {
                    onDiarized?(runs)
                }
            }

            publishTranscript(isFinal: message.from_finalize == true)
        } else {
            latestInterim = transcript
            publishTranscript(isFinal: false)
        }
    }

    private func publishTranscript(isFinal: Bool) {
        let transcript = currentTranscript()
        DispatchQueue.main.async { [weak self] in
            self?.onTranscript?(transcript, isFinal)
        }
    }

    private func currentTranscript() -> String {
        let finalText = finalSegments.joined(separator: " ")
        if latestInterim.isEmpty {
            return finalText
        }

        if finalText.isEmpty {
            return latestInterim
        }

        return "\(finalText) \(latestInterim)"
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private var openContinuation: CheckedContinuation<Bool, Never>?
    var lastError: String?

    func waitForOpen(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            openContinuation = continuation

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let continuation = self.openContinuation else {
                    return
                }

                self.openContinuation = nil
                self.lastError = "Timed out after \(Int(timeout)) seconds."
                continuation.resume(returning: false)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        openContinuation?.resume(returning: true)
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }

        if let response = task.response as? HTTPURLResponse {
            let deepgramError = response.value(forHTTPHeaderField: "dg-error")
            lastError = [String(response.statusCode), deepgramError].compactMap { $0 }.joined(separator: ": ")
        } else {
            lastError = error.localizedDescription
        }

        openContinuation?.resume(returning: false)
        openContinuation = nil
    }
}
