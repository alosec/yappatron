import Foundation
import FluidAudio

/// Wraps FluidAudio's DiarizerManager to produce a single 256-dim speaker embedding
/// from a finite audio sample. Used both for enrollment and for runtime verification.
///
/// This is intentionally a thin shared wrapper: model load is expensive, so callers
/// should hold a single VoiceEmbeddingExtractor instance for the lifetime of the engine.
actor VoiceEmbeddingExtractor {

    private var diarizer: DiarizerManager?
    private var ready: Bool = false

    /// Download (if needed) and load the diarizer models. Idempotent.
    func loadIfNeeded() async throws {
        if ready { return }

        log("VoiceEmbeddingExtractor: loading FluidAudio diarizer models...")
        let models = try await DiarizerModels.downloadIfNeeded()

        let manager = DiarizerManager()
        manager.initialize(models: consume models)

        self.diarizer = manager
        self.ready = true
        log("VoiceEmbeddingExtractor: ready")
    }

    /// Extract a single representative embedding for the dominant speaker in `samples`.
    ///
    /// Strategy: run diarization, then return the embedding of the longest-duration
    /// speaker segment. For enrollment audio (one person reading a paragraph) this is
    /// the user. For runtime verification windows (~1s of speech) the result is a
    /// single segment whose embedding represents that speech window.
    ///
    /// - Parameter samples: 16kHz mono Float32 PCM
    /// - Returns: nil if diarizer found no speech / failed to produce a usable embedding
    func extractDominantEmbedding(from samples: [Float]) async -> [Float]? {
        guard ready, let diarizer else {
            log("VoiceEmbeddingExtractor: not ready, cannot extract")
            return nil
        }

        guard !samples.isEmpty else { return nil }

        do {
            let result = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)
            guard !result.segments.isEmpty else {
                log("VoiceEmbeddingExtractor: no speech segments produced")
                return nil
            }

            // Pick the segment with the longest duration as the dominant speaker.
            let dominant = result.segments.max { lhs, rhs in
                (lhs.endTimeSeconds - lhs.startTimeSeconds) < (rhs.endTimeSeconds - rhs.startTimeSeconds)
            }
            return dominant?.embedding
        } catch {
            log("VoiceEmbeddingExtractor: extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Cosine distance between two L2-normalized embeddings (0 = identical, 2 = opposite).
    /// Pure function — provided here so callers don't need to import FluidAudio internals.
    nonisolated static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return Float.greatestFiniteMagnitude }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        // Inputs are expected to be L2-normalized — cosine distance = 1 - dot.
        return 1.0 - dot
    }
}
