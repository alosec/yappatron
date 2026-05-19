import Foundation

final class WebhookClient {
    enum WebhookError: LocalizedError {
        case invalidURL
        case http(Int, String)
        case encoding(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Webhook URL is not a valid HTTP URL."
            case .http(let code, let body):
                return "Webhook returned HTTP \(code): \(body.prefix(200))"
            case .encoding(let error):
                return error.localizedDescription
            }
        }

        var isTransient: Bool {
            switch self {
            case .http(let code, _):
                return code >= 500 || code == 429
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
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func send(_ payload: TranscriptWebhookPayload, to urlString: String, bearerToken: String? = nil) async throws {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WebhookError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw WebhookError.encoding(error)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(http.statusCode) else {
            throw WebhookError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
