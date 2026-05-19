import Foundation

struct TranscriptWebhookPayload: Codable {
    let event_type: String
    let event_id: String
    let session_id: String
    let source: String
    let channelId: String
    let text: String
    let formatted_text: String?
    let append_text: String?
    let is_final: Bool
    let sequence: Int
    let timestamp: String

    init(
        text: String,
        sessionID: String,
        sequence: Int,
        channelId: String = "voice",
        source: String = "yappatron-mac"
    ) {
        self.event_type = "yappatron.utterance.v1"
        self.event_id = UUID().uuidString
        self.session_id = sessionID
        self.source = source
        self.channelId = channelId
        self.text = text
        self.formatted_text = text
        self.append_text = text
        self.is_final = true
        self.sequence = sequence
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
}
