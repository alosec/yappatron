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
        let speech_final: Bool?
        let from_finalize: Bool?
        let message: String?
    }

    var onTranscript: ((String, Bool) -> Void)?
    /// Called once per completed utterance with diarized runs aggregated across
    /// Deepgram `is_final` fragments. Empty array if Deepgram didn't return word
    /// data (e.g. diarize disabled or short interim).
    var onDiarizedFinal: ((DeepgramDiarizedTurn) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let commitPolicy: DeepgramCommitPolicy
    private var session: URLSession?
    private var sessionDelegate: WebSocketDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private var finalSegments: [String] = []
    private var latestInterim = ""
    private var currentUtterance = ""
    private var currentDiarizedRuns: [DiarizedRun] = []
    private var isConnected = false
    private var eouTask: Task<Void, Never>?
    private var eouGeneration = 0
    private var finalizeContinuation: CheckedContinuation<String, Never>?
    private var finalizeTimeoutTask: Task<Void, Never>?

    init(apiKey: String, commitPolicy: DeepgramCommitPolicy) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.commitPolicy = commitPolicy
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
            URLQueryItem(name: "endpointing", value: "650"),
            URLQueryItem(name: "utterance_end_ms", value: "1000")
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

        eouTask?.cancel()
        eouTask = nil

        return await withCheckedContinuation { continuation in
            finalizeContinuation?.resume(returning: currentTranscript())
            finalizeContinuation = continuation

            finalizeTimeoutTask?.cancel()
            finalizeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self?.completeFinalize()
            }

            Task { [weak self] in
                do {
                    try await webSocketTask.send(.string("{\"type\":\"Finalize\"}"))
                } catch {
                    self?.completeFinalize()
                }
            }
        }
    }

    func disconnect() async {
        isConnected = false
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        eouTask?.cancel()
        finalizeTimeoutTask?.cancel()
        finalizeContinuation?.resume(returning: currentTranscript())
        receiveTask = nil
        keepAliveTask = nil
        eouTask = nil
        finalizeTimeoutTask = nil
        finalizeContinuation = nil

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
        case "UtteranceEnd":
            scheduleEOU(reason: .utteranceEnd, delayMs: commitPolicy.utteranceEndGraceMs)
        case "Error":
            DispatchQueue.main.async { [weak self] in
                self?.onError?(message.message ?? "Unknown Deepgram error.")
            }
        default:
            break
        }
    }

    private func handleResults(_ message: Message) {
        guard let alternative = message.channel?.alternatives.first else {
            return
        }
        let transcript = alternative.transcript

        if transcript.isEmpty {
            if message.from_finalize == true {
                completeFinalize()
            } else if message.speech_final == true {
                if commitPolicy.speechFinalGraceMs == 0 {
                    emitPendingUtterance(reason: .speechFinal)
                } else {
                    scheduleEOU(reason: .speechFinalGrace, delayMs: commitPolicy.speechFinalGraceMs)
                }
            }
            return
        }

        if message.is_final == true {
            latestInterim = ""
            finalSegments.append(transcript)
            appendToPendingUtterance(transcript)

            if let words = alternative.words, !words.isEmpty {
                appendDiarizedRuns(words.intoRuns())
            }

            publishTranscript(isFinal: true)

            if message.from_finalize == true {
                completeFinalize()
            } else if message.speech_final == true {
                if commitPolicy.speechFinalGraceMs == 0 {
                    emitPendingUtterance(reason: .speechFinal)
                } else {
                    scheduleEOU(reason: .speechFinalGrace, delayMs: commitPolicy.speechFinalGraceMs)
                }
            } else {
                scheduleEOU(reason: .silenceDebounce, delayMs: commitPolicy.silenceDebounceMs)
            }
        } else {
            latestInterim = transcript
            publishTranscript(isFinal: false)
            scheduleEOU(reason: .silenceDebounce, delayMs: commitPolicy.silenceDebounceMs)
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

    private func appendToPendingUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if currentUtterance.isEmpty {
            currentUtterance = trimmed
        } else {
            currentUtterance += " \(trimmed)"
        }
    }

    private func appendDiarizedRuns(_ runs: [DiarizedRun]) {
        for run in runs {
            guard !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if let last = currentDiarizedRuns.last,
               last.speakerID == run.speakerID {
                currentDiarizedRuns[currentDiarizedRuns.count - 1] = DiarizedRun(
                    speakerID: last.speakerID,
                    text: "\(last.text) \(run.text)",
                    startSec: last.startSec,
                    endSec: run.endSec
                )
            } else {
                currentDiarizedRuns.append(run)
            }
        }
    }

    private func scheduleEOU(reason: DeepgramCommitReason, delayMs: UInt64) {
        eouTask?.cancel()
        eouGeneration += 1
        let generation = eouGeneration

        eouTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            guard self?.eouGeneration == generation else { return }
            self?.emitPendingUtterance(reason: reason)
        }
    }

    private func emitPendingUtterance(reason: DeepgramCommitReason) {
        if reason != .finalize, !latestInterim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleEOU(reason: .silenceDebounce, delayMs: commitPolicy.silenceDebounceMs)
            return
        }

        let utterance = currentUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }

        eouTask?.cancel()
        eouTask = nil
        eouGeneration += 1

        let runs = currentDiarizedRuns.isEmpty
            ? [DiarizedRun(speakerID: -1, text: utterance, startSec: 0, endSec: 0)]
            : currentDiarizedRuns
        let fullTranscript = currentTranscript()
        currentUtterance = ""
        currentDiarizedRuns = []

        let onTranscript = self.onTranscript
        let onDiarized = self.onDiarizedFinal
        let turn = DeepgramDiarizedTurn(
            runs: runs,
            fullTranscript: fullTranscript,
            reason: reason,
            emittedAt: Date()
        )
        print("Deepgram commit reason=\(reason.rawValue) runs=\(runs.count) chars=\(utterance.count)")
        DispatchQueue.main.async {
            onDiarized?(turn)
            onTranscript?(fullTranscript, true)
        }
    }

    private func completeFinalize() {
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil

        emitPendingUtterance(reason: .finalize)

        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil
        continuation.resume(returning: currentTranscript())
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
