import Foundation

/// Posts diarized utterances to a user-configured webhook URL. One async POST
/// per finalized utterance. Single retry on transient failure (5xx or network
/// error); 4xx returns immediately. No queue, no buffering — kept dumb on
/// purpose so failures are visible and don't pile up across a long session.
final class WebhookClient {
    enum WebhookError: LocalizedError {
        case invalidURL
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Webhook URL is not a valid HTTPS URL."
            case .http(let code, let body):
                let snippet = body.prefix(200)
                return "Webhook returned HTTP \(code): \(snippet)"
            }
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        // Allow background URL tasks to start even if the system is dimming
        // backgrounded apps. The app declares UIBackgroundModes: audio, so a
        // legitimate ambient-listening session keeps these requests flying.
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Fire-and-forget post. Caller doesn't await delivery; success/failure
    /// is reported through `onResult` if set.
    var onResult: ((Result<Void, Error>) -> Void)?

    func send(_ utterance: DiarizedUtterance, to urlString: String, bearerToken: String?) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            onResult?(.failure(WebhookError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let payload: Data
        do {
            payload = try JSONEncoder().encode(utterance)
        } catch {
            onResult?(.failure(error))
            return
        }
        request.httpBody = payload

        Task { [session, onResult] in
            await Self.attempt(session: session, request: request, retriesRemaining: 1, report: onResult)
        }
    }

    private static func attempt(
        session: URLSession,
        request: URLRequest,
        retriesRemaining: Int,
        report: ((Result<Void, Error>) -> Void)?
    ) async {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                report?(.failure(URLError(.badServerResponse)))
                return
            }
            if (200...299).contains(http.statusCode) {
                report?(.success(()))
                return
            }
            // 5xx → retry once. 4xx → fail fast.
            if http.statusCode >= 500 && retriesRemaining > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await attempt(session: session, request: request, retriesRemaining: retriesRemaining - 1, report: report)
                return
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            report?(.failure(WebhookError.http(http.statusCode, body)))
        } catch {
            if retriesRemaining > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await attempt(session: session, request: request, retriesRemaining: retriesRemaining - 1, report: report)
                return
            }
            report?(.failure(error))
        }
    }
}
