import Foundation

/// Posts diarized utterances to a user-configured webhook URL. Retry and queue
/// state live in `WebhookOutbox`; this client only performs one HTTP attempt.
final class WebhookClient {
    enum WebhookError: LocalizedError {
        case invalidURL
        case http(Int, String)
        case encoding(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Webhook URL is not a valid HTTPS URL."
            case .http(let code, let body):
                let snippet = body.prefix(200)
                return "Webhook returned HTTP \(code): \(snippet)"
            case .encoding(let error):
                return error.localizedDescription
            }
        }

        var isTransient: Bool {
            switch self {
            case .http(let code, _):
                return code >= 500
            case .invalidURL, .encoding:
                return false
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

    func send(_ utterance: DiarizedUtterance, to urlString: String, bearerToken: String?) async throws {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw WebhookError.invalidURL
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
            throw WebhookError.encoding(error)
        }
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WebhookError.http(http.statusCode, body)
        }
    }
}
