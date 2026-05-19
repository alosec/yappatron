import Foundation

enum WebhookDeliveryStatus: String {
    case queued = "Queued"
    case sending = "Sending"
    case retrying = "Retrying"
    case sent = "Sent"
    case failed = "Failed"
}

struct WebhookDeliveryEvent {
    let id: String
    let status: WebhookDeliveryStatus
    let text: String
    let detail: String?
}

@MainActor
final class WebhookOutbox {
    var onEvent: ((WebhookDeliveryEvent) -> Void)?

    private let client: WebhookClient
    private var activeTasks: [String: Task<Void, Never>] = [:]

    init(client: WebhookClient = WebhookClient()) {
        self.client = client
    }

    func enqueue(_ payload: TranscriptWebhookPayload, to urlString: String, bearerToken: String? = nil) {
        report(WebhookDeliveryEvent(
            id: payload.event_id,
            status: .queued,
            text: payload.text,
            detail: "Queued for webhook"
        ))

        activeTasks[payload.event_id]?.cancel()
        activeTasks[payload.event_id] = Task { [weak self] in
            await self?.sendWithRetry(payload, to: urlString, bearerToken: bearerToken)
        }
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }

    private func sendWithRetry(_ payload: TranscriptWebhookPayload, to urlString: String, bearerToken: String?) async {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }

            report(WebhookDeliveryEvent(
                id: payload.event_id,
                status: attempt == 1 ? .sending : .retrying,
                text: payload.text,
                detail: attempt == 1 ? "Sending" : "Retry \(attempt) of \(maxAttempts)"
            ))

            do {
                try await client.send(payload, to: urlString, bearerToken: bearerToken)
                report(WebhookDeliveryEvent(
                    id: payload.event_id,
                    status: .sent,
                    text: payload.text,
                    detail: "Webhook accepted"
                ))
                activeTasks[payload.event_id] = nil
                return
            } catch {
                guard attempt < maxAttempts, shouldRetry(error) else {
                    report(WebhookDeliveryEvent(
                        id: payload.event_id,
                        status: .failed,
                        text: payload.text,
                        detail: error.localizedDescription
                    ))
                    activeTasks[payload.event_id] = nil
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

        return error is URLError
    }

    private func report(_ event: WebhookDeliveryEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
