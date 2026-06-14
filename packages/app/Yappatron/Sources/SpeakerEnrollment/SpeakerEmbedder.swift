import Foundation

#if YAPPATRON_ENABLE_FLUIDAUDIO
import FluidAudio
#endif

/// Wraps FluidAudio's DiarizerManager to produce a single 256-dim L2-normalized
/// embedding from a 16kHz mono audio sample. One shared instance lives for the
/// app session; model load is expensive.
#if YAPPATRON_ENABLE_FLUIDAUDIO
actor SpeakerEmbedder {

    private var diarizer: DiarizerManager?
    private var ready = false

    func loadIfNeeded() async throws {
        if ready { return }
        log("SpeakerEmbedder: downloading FluidAudio diarizer models...")
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: consume models)
        self.diarizer = manager
        self.ready = true
        log("SpeakerEmbedder: ready")
    }

    /// Extract a single speaker embedding from `samples` (16kHz mono Float32).
    /// Returns nil if the audio is too short or model produces no usable result.
    func embedding(for samples: [Float]) async -> [Float]? {
        guard ready, let diarizer else { return nil }
        guard !samples.isEmpty else { return nil }
        do {
            let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
            return diarizer.validateEmbedding(embedding) ? embedding : nil
        } catch {
            log("SpeakerEmbedder: extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Cosine distance between two L2-normalized embeddings.
    /// 0 = identical, 2 = opposite. Returns +inf on length mismatch.
    nonisolated static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return 1.0 - dot
    }
}
#else
actor SpeakerEmbedder {

    func loadIfNeeded() async throws {
        throw NSError(
            domain: "SpeakerEmbedder",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Speaker enrollment requires a FluidAudio-enabled macOS 14 build."]
        )
    }

    func embedding(for samples: [Float]) async -> [Float]? {
        nil
    }

    nonisolated static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return 1.0 - dot
    }
}
#endif
