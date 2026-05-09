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
