import Foundation
import FluidAudio
import CoreML

/// Thread-safe batch ASR processor using Parakeet TDT 0.6b
/// Provides higher accuracy and punctuation/capitalization output
actor BatchProcessor {

    enum Status: Equatable {
        case uninitialized
        case downloading
        case ready
        case error(String)
    }

    private(set) var status: Status = .uninitialized
    private var asrManager: AsrManager?

    func initialize() async throws {
        status = .downloading
        log("[BatchProcessor] Initializing Parakeet TDT 0.6b...")

        do {
            // Download and load TDT v3 models (multilingual, includes punctuation)
            let models = try await AsrModels.downloadAndLoad(version: .v3)

            // Create ASR manager with default config
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)

            self.asrManager = manager
            status = .ready
            log("[BatchProcessor] Batch processor ready (TDT 0.6b v3)")

        } catch {
            status = .error(error.localizedDescription)
            log("[BatchProcessor] Initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Process audio samples and return refined transcription
    /// - Parameter samples: 16kHz mono Float32 audio samples
    /// - Returns: Transcription with punctuation and capitalization
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager = asrManager else {
            throw NSError(
                domain: "BatchProcessor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Batch processor not initialized"]
            )
        }

        guard status == .ready else {
            throw NSError(
                domain: "BatchProcessor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Batch processor not ready: \(status)"]
            )
        }

        let startTime = Date()

        // Process samples through batch ASR
        let result = try await manager.transcribe(samples, source: .system)

        let elapsed = Date().timeIntervalSince(startTime)
        let audioLength = Float(samples.count) / 16000.0
        let rtf = elapsed / Double(audioLength)

        log("[BatchProcessor] Transcribed \(String(format: "%.1f", audioLength))s audio in \(String(format: "%.0f", elapsed * 1000))ms (RTF: \(String(format: "%.1f", rtf))x)")

        return result.text
    }
}
