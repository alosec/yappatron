import Foundation

enum DeepgramCommitReason: String, Codable {
    case speechFinal = "speech_final"
    case speechFinalGrace = "speech_final_grace"
    case utteranceEnd = "utterance_end"
    case silenceDebounce = "silence_debounce"
    case finalize = "finalize"
    case localFinal = "local_final"
}

struct DeepgramCommitPolicy {
    enum Mode {
        case responsive
        case conservative
    }

    let mode: Mode
    let silenceDebounceMs: UInt64
    let speechFinalGraceMs: UInt64
    let utteranceEndGraceMs: UInt64

    static func make(mode: Mode, thoughtPauseSeconds: Double) -> DeepgramCommitPolicy {
        let pauseMs = UInt64(max(2.0, min(thoughtPauseSeconds, 6.0)) * 1_000)

        switch mode {
        case .responsive:
            return DeepgramCommitPolicy(
                mode: mode,
                silenceDebounceMs: min(pauseMs, 2_750),
                speechFinalGraceMs: 0,
                utteranceEndGraceMs: 0
            )
        case .conservative:
            return DeepgramCommitPolicy(
                mode: mode,
                silenceDebounceMs: pauseMs,
                speechFinalGraceMs: pauseMs,
                utteranceEndGraceMs: min(1_000, pauseMs / 3)
            )
        }
    }
}

struct DeepgramDiarizedTurn {
    let runs: [DiarizedRun]
    let fullTranscript: String
    let reason: DeepgramCommitReason
    let emittedAt: Date
}
