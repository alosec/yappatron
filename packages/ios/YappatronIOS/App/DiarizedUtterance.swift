import Foundation

/// Wire-format utterance posted to the configured webhook URL once the
/// Deepgram `is_final` flag fires for a turn. One POST per finalized turn —
/// partials/interim updates are never sent.
struct DiarizedUtterance: Codable {
    let session_id: String
    let speaker: String?
    let speaker_id: Int?
    let text: String
    let start_ms: Int
    let end_ms: Int
    let is_final: Bool
    let source: String?
    let sequence: Int?
    let should_press_return: Bool?
}

struct TranscriptOutputSettings {
    let streamToWebhook: Bool
    let webhookURL: String
    let webhookToken: String
    let sendToKeyboard: Bool
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
    case sent = "Sent"
    case failed = "Failed"
}

struct TranscriptOutputEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let destination: TranscriptOutputDestination
    let status: TranscriptOutputStatus
    let text: String
    let detail: String?
}

enum TranscriptOutputRouter {
    static func deliver(
        _ utterance: DiarizedUtterance,
        settings: TranscriptOutputSettings,
        sharedStore: SharedTranscriptStore,
        webhookClient: WebhookClient
    ) -> [TranscriptOutputEvent] {
        var events: [TranscriptOutputEvent] = []

        if settings.sendToKeyboard {
            sharedStore.saveTranscript(utterance.text)
            events.append(TranscriptOutputEvent(
                destination: .keyboard,
                status: .queued,
                text: utterance.text,
                detail: "Ready for auto-insert"
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
            webhookClient.send(
                utterance,
                to: settings.webhookURL,
                bearerToken: settings.webhookToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : settings.webhookToken
            )
            events.append(TranscriptOutputEvent(
                destination: .webhook,
                status: .queued,
                text: utterance.text,
                detail: nil
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
