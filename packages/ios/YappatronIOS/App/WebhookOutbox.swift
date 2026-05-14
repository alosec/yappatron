import Foundation

final class WebhookOutbox {
    var onEvent: ((TranscriptOutputEvent) -> Void)?

    private let client: WebhookClient
    private var activeTasks: [String: Task<Void, Never>] = [:]

    init(client: WebhookClient = WebhookClient()) {
        self.client = client
    }

    @discardableResult
    func enqueue(_ utterance: DiarizedUtterance, to urlString: String, bearerToken: String?) -> TranscriptOutputEvent {
        let queued = makeEvent(
            utterance: utterance,
            status: .queued,
            detail: utterance.commit_reason.map { "Waiting to send (\($0))" }
        )

        activeTasks[utterance.event_id]?.cancel()
        activeTasks[utterance.event_id] = Task { [weak self] in
            await self?.sendWithRetry(utterance, to: urlString, bearerToken: bearerToken)
        }

        return queued
    }

    func sendTransient(_ utterance: DiarizedUtterance, to urlString: String, bearerToken: String?) {
        Task { [client] in
            try? await client.send(utterance, to: urlString, bearerToken: bearerToken)
        }
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }

    private func sendWithRetry(_ utterance: DiarizedUtterance, to urlString: String, bearerToken: String?) async {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            report(makeEvent(
                utterance: utterance,
                status: attempt == 1 ? .sending : .retrying,
                detail: attempt == 1 ? "Sending" : "Retry \(attempt) of \(maxAttempts)"
            ))

            do {
                try await client.send(utterance, to: urlString, bearerToken: bearerToken)
                report(makeEvent(utterance: utterance, status: .sent, detail: "Webhook accepted"))
                activeTasks[utterance.event_id] = nil
                return
            } catch {
                guard attempt < maxAttempts, shouldRetry(error) else {
                    report(makeEvent(utterance: utterance, status: .failed, detail: error.localizedDescription))
                    activeTasks[utterance.event_id] = nil
                    return
                }

                let backoffNs = UInt64(attempt) * 900_000_000
                try? await Task.sleep(nanoseconds: backoffNs)
            }
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let webhookError = error as? WebhookClient.WebhookError {
            return webhookError.isTransient
        }

        if error is URLError {
            return true
        }

        return false
    }

    private func makeEvent(
        utterance: DiarizedUtterance,
        status: TranscriptOutputStatus,
        detail: String?
    ) -> TranscriptOutputEvent {
        TranscriptOutputEvent(
            id: utterance.event_id,
            destination: .webhook,
            status: status,
            text: utterance.formatted_text ?? utterance.text,
            detail: detail
        )
    }

    private func report(_ event: TranscriptOutputEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
