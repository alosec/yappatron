import Foundation

/// Wire-format transcript event posted to the configured webhook URL.
/// `append_text` is the relay-safe, append-only text that should be pasted.
struct DiarizedUtterance: Codable {
    let event_type: String?
    let event_id: String
    let session_id: String
    let speaker: String?
    let speaker_id: Int?
    let text: String
    let append_text: String?
    let formatted_text: String?
    let start_ms: Int
    let end_ms: Int
    let is_final: Bool
    let source: String?
    let sequence: Int?
    let should_press_return: Bool?
    let commit_reason: String?
    let runs: [DiarizedUtteranceRun]?
}

struct DiarizedUtteranceRun: Codable {
    let speaker: String?
    let speaker_id: Int?
    let text: String
    let start_ms: Int
    let end_ms: Int
}

struct TranscriptOutputSettings {
    let streamToWebhook: Bool
    let webhookURL: String
    let webhookToken: String
    let autoInsertOnKeyboardOpen: Bool
    let pressReturnAfterSend: Bool
}

enum TranscriptOutputDestination: String {
    case webhook = "Webhook"
    case keyboard = "Keyboard"
    case returnKey = "Return"

    var symbolName: String {
        switch self {
        case .webhook:
            return "antenna.radiowaves.left.and.right"
        case .keyboard:
            return "keyboard"
        case .returnKey:
            return "return"
        }
    }
}

enum TranscriptOutputStatus: String {
    case queued = "Queued"
    case sending = "Sending"
    case retrying = "Retrying"
    case sent = "Sent"
    case failed = "Failed"
}

struct TranscriptOutputEvent: Identifiable, Equatable {
    let id: String
    let timestamp = Date()
    let destination: TranscriptOutputDestination
    let status: TranscriptOutputStatus
    let text: String
    let detail: String?

    init(
        id: String = UUID().uuidString,
        destination: TranscriptOutputDestination,
        status: TranscriptOutputStatus,
        text: String,
        detail: String?
    ) {
        self.id = id
        self.destination = destination
        self.status = status
        self.text = text
        self.detail = detail
    }
}

enum TranscriptOutputRouter {
    static func deliver(
        _ utterance: DiarizedUtterance,
        settings: TranscriptOutputSettings,
        sharedStore: SharedTranscriptStore,
        webhookOutbox: WebhookOutbox
    ) -> [TranscriptOutputEvent] {
        var events: [TranscriptOutputEvent] = []

        sharedStore.saveTranscript(utterance.text)

        if settings.autoInsertOnKeyboardOpen {
            events.append(TranscriptOutputEvent(
                destination: .keyboard,
                status: .queued,
                text: utterance.text,
                detail: "Keyboard will insert this chunk"
            ))

            if settings.pressReturnAfterSend {
                events.append(TranscriptOutputEvent(
                    destination: .returnKey,
                    status: .queued,
                    text: "Return after insert",
                    detail: nil
                ))
            }
        }

        if settings.streamToWebhook && !settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(webhookOutbox.enqueue(
                utterance,
                to: settings.webhookURL,
                bearerToken: settings.webhookToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : settings.webhookToken
            ))
        }

        return events
    }
}

/// Word-level item from a Deepgram `Results` message when `diarize=true`.
struct DiarizedWord: Decodable {
    let word: String
    let punctuated_word: String?
    let start: Double
    let end: Double
    let speaker: Int?
    let confidence: Double?
}

/// Aggregated run: consecutive words from the same speaker inside one
/// finalized turn. Built locally on-device from the word array.
struct DiarizedRun {
    let speakerID: Int
    let text: String
    let startSec: Double
    let endSec: Double
}

extension Array where Element == DiarizedWord {
    /// Aggregate consecutive same-speaker words into runs. Words with a nil
    /// speaker fall through into the previous run if any, otherwise into a
    /// fresh run with speakerID = -1 (unknown).
    func intoRuns() -> [DiarizedRun] {
        var runs: [DiarizedRun] = []
        var currentSpeaker: Int? = nil
        var currentWords: [DiarizedWord] = []

        func flush() {
            guard !currentWords.isEmpty else { return }
            let text = currentWords
                .map { $0.punctuated_word ?? $0.word }
                .joined(separator: " ")
            let start = currentWords.first!.start
            let end = currentWords.last!.end
            runs.append(DiarizedRun(
                speakerID: currentSpeaker ?? -1,
                text: text,
                startSec: start,
                endSec: end
            ))
            currentWords.removeAll(keepingCapacity: true)
        }

        for w in self {
            let speaker = w.speaker
            if speaker != currentSpeaker {
                flush()
                currentSpeaker = speaker
            }
            currentWords.append(w)
        }
        flush()
        return runs
    }
}
