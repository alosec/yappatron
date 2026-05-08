import Foundation

/// One run of words attributed to a single speaker, with the audio that produced it.
struct DiarizedRunWithAudio {
    let deepgramSpeakerId: Int
    let text: String
    let samples: [Float]   // 16kHz mono Float32 audio for this run only
}

/// One run after the hybrid override pass. If `enrolledName` is non-nil, the
/// embedding match was strong enough to override Deepgram's ID and we should
/// type that name. Otherwise fall back to `SpeakerLabelMap` for the original ID.
struct OverriddenRun {
    let deepgramSpeakerId: Int
    let text: String
    let enrolledName: String?
    let matchDistance: Float?  // nil if no embedding extracted, for telemetry
}

/// Audits Deepgram's per-run speaker IDs against locally enrolled voiceprints.
/// When the embedding match for a run is closer to an enrolled speaker than
/// the configured threshold, the run is relabeled with that speaker's name.
/// Otherwise Deepgram's ID is preserved and the existing rename UI flow applies.
actor HybridDiarizer {

    private let embedder: SpeakerEmbedder

    /// Maximum cosine distance to accept as a match. Lower = stricter.
    /// FluidAudio recommends ~0.65 for clustering; we use a tighter default
    /// so that we only override when we're confident.
    var threshold: Float = 0.45

    /// Minimum audio duration (seconds) to bother running embedding on.
    /// 0 = always run override; never fall through to Deepgram's IDs based on
    /// duration alone. Embeddings on very short audio are noisier but Deepgram's
    /// short-utterance IDs proved less trustworthy than letting the embedding
    /// pass make the call (even if marginal).
    var minRunSeconds: Float = 0.0

    private let sampleRate: Float = 16000

    init(embedder: SpeakerEmbedder) {
        self.embedder = embedder
    }

    /// Override Deepgram's IDs for each run by matching audio to enrolled embeddings.
    func override(
        runs: [DiarizedRunWithAudio],
        enrolled: [EnrolledSpeaker]
    ) async -> [OverriddenRun] {
        guard !enrolled.isEmpty else {
            return runs.map { OverriddenRun(deepgramSpeakerId: $0.deepgramSpeakerId, text: $0.text, enrolledName: nil, matchDistance: nil) }
        }

        do {
            try await embedder.loadIfNeeded()
        } catch {
            log("HybridDiarizer: embedder load failed: \(error.localizedDescription)")
            return runs.map { OverriddenRun(deepgramSpeakerId: $0.deepgramSpeakerId, text: $0.text, enrolledName: nil, matchDistance: nil) }
        }

        var out: [OverriddenRun] = []
        out.reserveCapacity(runs.count)

        for run in runs {
            let durationSec = Float(run.samples.count) / sampleRate
            guard durationSec >= minRunSeconds else {
                log("HybridDiarizer: skip short run (\(String(format: "%.2f", durationSec))s) — '\(run.text.prefix(40))'")
                out.append(OverriddenRun(deepgramSpeakerId: run.deepgramSpeakerId, text: run.text, enrolledName: nil, matchDistance: nil))
                continue
            }

            guard let embedding = await embedder.embedding(for: run.samples) else {
                log("HybridDiarizer: no embedding for run — '\(run.text.prefix(40))'")
                out.append(OverriddenRun(deepgramSpeakerId: run.deepgramSpeakerId, text: run.text, enrolledName: nil, matchDistance: nil))
                continue
            }

            // Find closest enrolled speaker
            var best: (speaker: EnrolledSpeaker, distance: Float)?
            for enr in enrolled {
                let d = SpeakerEmbedder.cosineDistance(embedding, enr.embedding)
                if best == nil || d < best!.distance {
                    best = (enr, d)
                }
            }

            // Distances against ALL enrolled — useful for debugging flips.
            let allDistances = enrolled.map { e -> String in
                let d = SpeakerEmbedder.cosineDistance(embedding, e.embedding)
                return String(format: "%@=%.3f", e.name, d)
            }.joined(separator: " ")

            if let best = best, best.distance <= threshold {
                let msg = "OVERRIDE dgId=\(run.deepgramSpeakerId) -> '\(best.speaker.name)' (distance=\(String(format: "%.3f", best.distance))) [\(allDistances)] runDur=\(String(format: "%.2f", durationSec))s text='\(run.text.prefix(60))'"
                log("HybridDiarizer: \(msg)")
                HybridDiagLog.shared.write(msg)
                out.append(OverriddenRun(
                    deepgramSpeakerId: run.deepgramSpeakerId,
                    text: run.text,
                    enrolledName: best.speaker.name,
                    matchDistance: best.distance
                ))
            } else {
                let bestStr = best.map { String(format: "%.3f→%@", $0.distance, $0.speaker.name) } ?? "none"
                let msg = "KEEP dgId=\(run.deepgramSpeakerId) (best=\(bestStr), threshold=\(threshold)) [\(allDistances)] runDur=\(String(format: "%.2f", durationSec))s text='\(run.text.prefix(60))'"
                log("HybridDiarizer: \(msg)")
                HybridDiagLog.shared.write(msg)
                out.append(OverriddenRun(
                    deepgramSpeakerId: run.deepgramSpeakerId,
                    text: run.text,
                    enrolledName: nil,
                    matchDistance: best?.distance
                ))
            }
        }

        return out
    }
}
