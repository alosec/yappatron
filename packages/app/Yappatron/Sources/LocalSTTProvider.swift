import Foundation
#if YAPPATRON_ENABLE_FLUIDAUDIO
import FluidAudio
import AVFoundation
import CoreML
#else
import AVFoundation
#endif

/// Local Nemotron-based streaming STT provider, gated by Silero VAD.
///
/// Uses FluidAudio's `StreamingNemotronAsrManager` (NVIDIA Nemotron Speech
/// Streaming 0.6B, 160ms cache-aware chunks). Unlike the older Parakeet EOU
/// 120M model, Nemotron punctuates and capitalizes *inline* as it streams and
/// is meaningfully more accurate — finished utterances are already punctuated
/// without a second pass.
///
/// Nemotron has no voice-activity gating or end-of-utterance detection. Fed
/// silence, it hallucinates phantom phrases ("Thank you.", "you", etc.). A
/// plain RMS gate isn't enough — a noisy mic floor trips it. So this provider
/// front-gates the model with FluidAudio's **Silero neural VAD**:
///
/// - Audio is only forwarded to Nemotron between Silero's `.speechStart` and
///   `.speechEnd` events. Silence/noise is never decoded.
/// - A short pre-roll of buffers is flushed on `.speechStart` so the first
///   word isn't clipped.
/// - `.speechEnd` finalizes the utterance and emits the punctuated final.
#if YAPPATRON_ENABLE_FLUIDAUDIO
class LocalSTTProvider: STTProvider {
    private var streamingManager: StreamingNemotronAsrManager?
    private var vad: VadManager?
    private var vadState: VadStreamState?
    private let audioConverter = AudioConverter()

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?

    /// Silero processes fixed 4096-sample (16kHz) chunks.
    private let vadChunkSamples = VadManager.chunkSize
    private var vadSampleBuffer: [Float] = []

    /// True between Silero `.speechStart` and `.speechEnd` — only then do we decode.
    private var inSpeech = false
    private var isFinalizing = false

    /// Recent buffers kept as pre-roll so onset doesn't clip the first word.
    private let preRollBufferCount = 4
    private var preRoll: [AVAudioPCMBuffer] = []

    func start() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let manager = StreamingNemotronAsrManager(
            configuration: config,
            requestedChunkSize: .ms160
        )
        // Downloads from HuggingFace on first use, then loads from cache.
        try await manager.loadModels()
        await manager.setPartialCallback { [weak self] partial in
            guard let self = self, self.inSpeech else { return }
            self.onPartial?(partial)
        }
        streamingManager = manager

        // Silero VAD gate (downloads its small CoreML model on first use).
        let vadManager = try await VadManager()
        vad = vadManager
        vadState = await vadManager.makeStreamState()

        log("LocalSTTProvider: Nemotron 0.6B (160ms) + Silero VAD ready")
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard let manager = streamingManager, let vad = vad else { return }

        // Convert to 16kHz mono Float for the VAD.
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

            guard var state = vadState else { break }
            let result = try await vad.processStreamingChunk(chunk, state: state)
            vadState = result.state

            if let event = result.event {
                if event.isStart {
                    try await handleSpeechStart(manager)
                } else if event.isEnd {
                    await handleSpeechEnd(manager)
                }
            }
            _ = state
        }

        // While speech is active, stream this buffer to Nemotron.
        if inSpeech {
            _ = try await manager.process(audioBuffer: buffer)
        }
    }

    private func handleSpeechStart(_ manager: StreamingNemotronAsrManager) async throws {
        guard !inSpeech else { return }
        inSpeech = true
        isFinalizing = false
        // Flush pre-roll so the first word isn't lost.
        for pre in preRoll {
            _ = try? await manager.process(audioBuffer: pre)
        }
        preRoll.removeAll()
    }

    private func handleSpeechEnd(_ manager: StreamingNemotronAsrManager) async {
        guard inSpeech, !isFinalizing else { return }
        isFinalizing = true
        inSpeech = false
        let text = (try? await manager.finish()) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onFinal?(trimmed)
        }
        await manager.reset()
        isFinalizing = false
    }

    func finishCurrentUtterance() async throws -> String? {
        guard inSpeech else { return nil }
        let text = try await streamingManager?.finish()
        inSpeech = false
        await streamingManager?.reset()
        return text
    }

    func finish() async throws -> String? {
        let wasSpeaking = inSpeech
        let text = try await streamingManager?.finish()
        inSpeech = false
        await streamingManager?.reset()
        return wasSpeaking ? text : nil
    }

    func reset() async {
        await streamingManager?.reset()
        if let vad = vad {
            vadState = await vad.makeStreamState()
        }
        vadSampleBuffer.removeAll()
        preRoll.removeAll()
        inSpeech = false
        isFinalizing = false
    }

    func cleanup() {
        streamingManager = nil
        vad = nil
        vadState = nil
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
