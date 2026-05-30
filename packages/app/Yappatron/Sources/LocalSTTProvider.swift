import Foundation
import FluidAudio
import AVFoundation
import CoreML

/// Local Parakeet-based STT provider (wraps existing StreamingEouAsrManager)
class LocalSTTProvider: STTProvider {
    private var streamingManager: StreamingEouAsrManager?

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?

    func start() async throws {
        let modelDir = try await downloadModels()

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        // Use the 160ms EOU chunk for the lowest-latency "instant" stream.
        // Finished utterances are punctuated/capitalized by the TDT-v3 dual-pass
        // (enabled by default for local mode in YappatronApp).
        let manager = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms160,
            eouDebounceMs: 800
        )

        try await manager.loadModels(from: modelDir)

        await manager.setPartialCallback { [weak self] partial in
            self?.onPartial?(partial)
        }

        await manager.setEouCallback { [weak self] final in
            self?.onFinal?(final)
        }

        streamingManager = manager
        log("LocalSTTProvider: Parakeet EOU 120M (160ms) ready")
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        _ = try await streamingManager?.process(audioBuffer: buffer)
    }

    func finishCurrentUtterance() async throws -> String? {
        return try await streamingManager?.finish()
    }

    func finish() async throws -> String? {
        return try await streamingManager?.finish()
    }

    func reset() async {
        await streamingManager?.reset()
    }

    func cleanup() {
        streamingManager = nil
    }

    // MARK: - Model Download

    private func downloadModels() async throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let modelPath = modelsDir.appendingPathComponent(Repo.parakeetEou160.folderName)

        let encoderPath = modelPath.appendingPathComponent("streaming_encoder.mlmodelc")
        if FileManager.default.fileExists(atPath: encoderPath.path) {
            log("LocalSTTProvider: Streaming models already cached")
            return modelPath
        }

        let actuallyNeeded = [
            ModelNames.ParakeetEOU.encoderFile,
            ModelNames.ParakeetEOU.decoderFile,
            ModelNames.ParakeetEOU.jointFile,
            ModelNames.ParakeetEOU.vocab
        ]

        _ = try await DownloadUtils.loadModels(
            .parakeetEou160,
            modelNames: actuallyNeeded,
            directory: modelsDir,
            computeUnits: .cpuAndNeuralEngine
        )

        return modelPath
    }
}
