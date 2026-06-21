import Foundation
#if YAPPATRON_ENABLE_FLUIDAUDIO
import FluidAudio
import AVFoundation
import CoreML
#else
import AVFoundation
#endif

/// Which local ASR engine the provider runs. Selected by the `localModel`
/// UserDefaults key. Surfaced in the menu as Backend → Local → "Local Model".
enum LocalModel: String, CaseIterable {
    case nemotron   // NVIDIA Nemotron Speech Streaming 0.6B — true 160ms streaming, very low latency
    case qwen3      // Qwen3-ASR 0.6B — higher accuracy, re-transcribes in ~1s chunks (less instant)

    static var current: LocalModel {
        let raw = UserDefaults.standard.string(forKey: "localModel") ?? "nemotron"
        let model = LocalModel(rawValue: raw) ?? .nemotron
        // Qwen3 requires macOS 15+. Fall back to Nemotron on older systems.
        if model == .qwen3, #unavailable(macOS 15) { return .nemotron }
        return model
    }

    var displayName: String {
        switch self {
        case .nemotron: return "Nemotron 0.6B (fastest)"
        case .qwen3: return "Qwen3-ASR 0.6B (most accurate)"
        }
    }
}

/// Local streaming STT provider, gated by Silero VAD.
///
/// Two engines are supported behind the same gate (see `LocalModel`):
///
/// - **Nemotron** (`StreamingNemotronAsrManager`, 160ms chunks): punctuates
///   inline as it streams, very low latency. Default.
/// - **Qwen3-ASR** (`Qwen3StreamingManager`, macOS 15+): higher accuracy, but
///   re-transcribes the accumulated buffer every ~1s, so partials are chunkier.
///
/// Neither engine has voice-activity gating or end-of-utterance detection, and
/// both hallucinate on silence. So a FluidAudio **Silero neural VAD** front-gate
/// drives everything: audio only reaches the ASR between `.speechStart` and
/// `.speechEnd`, and `.speechEnd` finalizes the utterance.
#if YAPPATRON_ENABLE_FLUIDAUDIO
class LocalSTTProvider: STTProvider {
    private let model = LocalModel.current

    // Nemotron engine
    private var nemotron: StreamingNemotronAsrManager?
    // Qwen3 engine (macOS 15+). Held as Any? so the stored property doesn't
    // require an availability annotation; calls are guarded by #available.
    private var qwen3Box: Any?

    // Silero VAD
    private var vad: VadManager?
    private var vadState: VadStreamState?
    private let audioConverter = AudioConverter()
    private let vadChunkSamples = VadManager.chunkSize
    private var vadSampleBuffer: [Float] = []

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?

    /// True between Silero `.speechStart` and `.speechEnd` — only then do we decode.
    private var inSpeech = false
    private var isFinalizing = false

    /// Recent buffers kept as pre-roll so onset doesn't clip the first word.
    private let preRollBufferCount = 4
    private var preRoll: [AVAudioPCMBuffer] = []

    func start() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        switch model {
        case .nemotron:
            let manager = StreamingNemotronAsrManager(
                configuration: config,
                requestedChunkSize: .ms160
            )
            try await manager.loadModels()
            await manager.setPartialCallback { [weak self] partial in
                guard let self = self, self.inSpeech else { return }
                self.onPartial?(partial)
            }
            nemotron = manager

        case .qwen3:
            if #available(macOS 15, *) {
                let engine = Qwen3Engine()
                try await engine.load()
                qwen3Box = engine
            } else {
                // Shouldn't happen (LocalModel.current falls back), but be safe.
                let manager = StreamingNemotronAsrManager(configuration: config, requestedChunkSize: .ms160)
                try await manager.loadModels()
                await manager.setPartialCallback { [weak self] partial in
                    guard let self = self, self.inSpeech else { return }
                    self.onPartial?(partial)
                }
                nemotron = manager
            }
        }

        // Silero VAD gate (downloads its small CoreML model on first use).
        let vadManager = try await VadManager()
        vad = vadManager
        vadState = await vadManager.makeStreamState()

        log("LocalSTTProvider: \(model.rawValue) + Silero VAD ready")
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard let vad = vad else { return }

        let samples = (try? audioConverter.resampleBuffer(buffer)) ?? []

        // Maintain a short pre-roll while idle so onset isn't clipped.
        if !inSpeech {
            preRoll.append(buffer)
            if preRoll.count > preRollBufferCount { preRoll.removeFirst() }
        }

        // Run the VAD over fixed-size chunks, handling start/end events.
        vadSampleBuffer.append(contentsOf: samples)
        while vadSampleBuffer.count >= vadChunkSamples {
            let chunk = Array(vadSampleBuffer.prefix(vadChunkSamples))
            vadSampleBuffer.removeFirst(vadChunkSamples)

            guard let state = vadState else { break }
            let result = try await vad.processStreamingChunk(chunk, state: state)
            vadState = result.state

            if let event = result.event {
                if event.isStart {
                    try await handleSpeechStart()
                } else if event.isEnd {
                    await handleSpeechEnd()
                }
            }
        }

        // While speech is active, stream this buffer to the active engine.
        if inSpeech {
            try await feed(buffer: buffer, samples: samples)
        }
    }

    // MARK: - Engine feed / lifecycle

    private func feed(buffer: AVAudioPCMBuffer, samples: [Float]) async throws {
        if let nemotron {
            _ = try await nemotron.process(audioBuffer: buffer)
        } else if #available(macOS 15, *), let engine = qwen3Box as? Qwen3Engine {
            if let partial = try await engine.addAudio(samples) {
                let t = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { onPartial?(t) }
            }
        }
    }

    private func handleSpeechStart() async throws {
        guard !inSpeech else { return }
        inSpeech = true
        isFinalizing = false
        for pre in preRoll {
            let preSamples = (try? audioConverter.resampleBuffer(pre)) ?? []
            try? await feed(buffer: pre, samples: preSamples)
        }
        preRoll.removeAll()
    }

    private func handleSpeechEnd() async {
        guard inSpeech, !isFinalizing else { return }
        isFinalizing = true
        inSpeech = false
        let text = await finishActiveEngine() ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onFinal?(trimmed) }
        await resetEngine()
        isFinalizing = false
    }

    func finishCurrentUtterance() async throws -> String? {
        guard inSpeech else { return nil }
        inSpeech = false
        let text = await finishActiveEngine()
        await resetEngine()
        return text
    }

    func finish() async throws -> String? {
        let wasSpeaking = inSpeech
        inSpeech = false
        let text = await finishActiveEngine()
        await resetEngine()
        return wasSpeaking ? text : nil
    }

    func reset() async {
        await resetEngine()
        if let vad = vad {
            vadState = await vad.makeStreamState()
        }
        vadSampleBuffer.removeAll()
        preRoll.removeAll()
        inSpeech = false
        isFinalizing = false
    }

    func cleanup() {
        nemotron = nil
        qwen3Box = nil
        vad = nil
        vadState = nil
    }

    private func finishActiveEngine() async -> String? {
        if let nemotron {
            return try? await nemotron.finish()
        } else if #available(macOS 15, *), let engine = qwen3Box as? Qwen3Engine {
            return try? await engine.finish()
        }
        return nil
    }

    private func resetEngine() async {
        if let nemotron {
            await nemotron.reset()
        } else if #available(macOS 15, *), let engine = qwen3Box as? Qwen3Engine {
            await engine.reset()
        }
    }
}

/// Thin wrapper around FluidAudio's Qwen3 streaming pipeline, isolated here so
/// the macOS 15+ availability requirement stays out of `LocalSTTProvider`.
@available(macOS 15, *)
final class Qwen3Engine {
    private var streaming: Qwen3StreamingManager?

    func load() async throws {
        // int8 variant: ~900MB, lighter fit for 16GB machines.
        let dir = try await Qwen3AsrModels.download(variant: .int8)
        let asr = Qwen3AsrManager()
        // Qwen3 isn't fully ANE-compatible — use .all (CPU+GPU+ANE), matching
        // FluidAudio's default. Forcing .cpuAndNeuralEngine fails with CoreML -14.
        try await asr.loadModels(from: dir, computeUnits: .all)
        // Snappier than the 2s default so partials update more often.
        // Pin to English — Qwen3 is multilingual and otherwise auto-detects,
        // sometimes drifting to Chinese on English speech.
        let config = Qwen3StreamingConfig(minAudioSeconds: 0.6, chunkSeconds: 0.8, language: .english)
        streaming = Qwen3StreamingManager(asrManager: asr, config: config)
    }

    /// Returns the current full transcript when a new chunk was decoded, else nil.
    func addAudio(_ samples: [Float]) async throws -> String? {
        try await streaming?.addAudio(samples)?.transcript
    }

    func finish() async throws -> String? {
        try await streaming?.finish().transcript
    }

    func reset() async {
        await streaming?.reset()
    }
}
#else
class LocalSTTProvider: STTProvider {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?

    func start() async throws {
        throw NSError(
            domain: "LocalSTTProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local STT requires a FluidAudio-enabled macOS 14 build."]
        )
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {}

    func finishCurrentUtterance() async throws -> String? {
        nil
    }

    func finish() async throws -> String? {
        nil
    }

    func reset() async {}

    func cleanup() {}
}
#endif
