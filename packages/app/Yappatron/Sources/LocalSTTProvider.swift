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

    func start() async throws {
        let modelDir = try await downloadModels()

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let manager = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms320,
            eouDebounceMs: 800
        )

        try await manager.loadModels(modelDir: modelDir)

        await manager.setPartialCallback { [weak self] partial in
            self?.onPartial?(partial)
        }

        await manager.setEouCallback { [weak self] final in
            self?.onFinal?(final)
        }

        streamingManager = manager
        log("LocalSTTProvider: Parakeet EOU ready")
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        _ = try await streamingManager?.process(audioBuffer: buffer)
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
        let modelPath = modelsDir.appendingPathComponent(Repo.parakeetEou320.folderName)

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
            .parakeetEou320,
            modelNames: actuallyNeeded,
            directory: modelsDir,
            computeUnits: .cpuAndNeuralEngine
        )

        return modelPath
    }
}
