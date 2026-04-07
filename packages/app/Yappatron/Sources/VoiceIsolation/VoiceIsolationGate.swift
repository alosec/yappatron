import AVFoundation
import Foundation

/// Decorator over an STTProvider that only forwards audio when the speaker matches
/// the enrolled user's voiceprint. Strangers' speech never reaches the inner provider
/// — no text leak, no Deepgram billing for non-user audio.
///
/// State machine, per "speech window":
///
///   idle ──speech──▶ accumulating ──≥1s of speech──▶ verify
///    ▲                    │                              │
///    │                    └──silence (too short)─────────┤
///    │                                                   │
///    │                                       ┌───match───┘
///    │                                       │
///    │                                       ▼
///    │                                   streaming ──silence──▶ idle
///    │                                       │
///    │                                       └──extended silence──▶ idle
///    │                                                   │
///    │                                       ┌──reject───┘
///    │                                       ▼
///    └──silence────────────────────────── dropping
///
/// Notes:
/// - "Speech" is detected via cheap RMS energy gating, not via a model.
///   This is fine because the speaker-verification step is the actual decision;
///   VAD only chunks the audio into windows.
/// - When verified, the *entire* buffered window is flushed to the inner provider
///   in order, so the user's first words appear intact (just delayed by ~1s on the
///   first utterance of a window).
/// - When rejected, the buffered window is dropped and reset() is called on the
///   inner provider so its own EOU/segment state is clean.
final class VoiceIsolationGate: STTProvider, @unchecked Sendable {

    // MARK: STTProvider conformance
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?

    // MARK: Dependencies
    private let inner: STTProvider
    private let extractor: VoiceEmbeddingExtractor
    private let enrolledEmbedding: [Float]
    private let threshold: Float

    // MARK: State machine
    private enum State {
        case idle
        case accumulating
        case streaming
        case dropping
    }
    private var state: State = .idle

    // MARK: Tunables
    /// Sample rate of incoming audio (we assume the engine has already converted to 16k mono).
    private let sampleRate: Double = 16000
    /// RMS threshold to consider a buffer as speech. Tuned conservative;
    /// the verification step is the real gate.
    private let speechRmsThreshold: Float = 0.005
    /// Minimum amount of buffered speech audio (in samples) before running verification.
    private var minVerifySamples: Int { Int(sampleRate * 1.0) }
    /// Number of consecutive silent buffers before we treat the window as ended.
    private let silenceBuffersToReset: Int = 8  // ~256ms * 8 ≈ 2s, well below EOU
    private var consecutiveSilentBuffers: Int = 0

    // MARK: Buffered audio while accumulating
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    // MARK: Stats (for debugging / future UI)
    private(set) var verifiedWindowsCount: Int = 0
    private(set) var rejectedWindowsCount: Int = 0

    // MARK: Init

    init(inner: STTProvider, extractor: VoiceEmbeddingExtractor, voiceprint: StoredVoiceprint, threshold: Float) {
        self.inner = inner
        self.extractor = extractor
        self.enrolledEmbedding = voiceprint.embedding
        self.threshold = threshold

        // Wire inner callbacks straight through. The gate only controls *what audio*
        // reaches the inner provider; once audio flows, transcription proceeds normally.
        self.inner.onPartial = { [weak self] partial in self?.onPartial?(partial) }
        self.inner.onFinal = { [weak self] final in self?.onFinal?(final) }
        self.inner.onLockedTextAdvanced = { [weak self] len in self?.onLockedTextAdvanced?(len) }

        log("VoiceIsolationGate: ready (threshold=\(threshold), enrolled='\(voiceprint.name)')")
    }

    // MARK: STTProvider methods

    func start() async throws {
        try await inner.start()
    }

    func processAudio(_ buffer: AVAudioPCMBuffer) async throws {
        let isSpeech = bufferIsSpeech(buffer)

        switch state {
        case .idle:
            if isSpeech {
                pendingBuffers.removeAll(keepingCapacity: true)
                pendingBuffers.append(copyBuffer(buffer))
                consecutiveSilentBuffers = 0
                state = .accumulating
            }
            // Otherwise: idle silence, ignore.

        case .accumulating:
            pendingBuffers.append(copyBuffer(buffer))
            if isSpeech {
                consecutiveSilentBuffers = 0
            } else {
                consecutiveSilentBuffers += 1
            }

            // Have we accumulated enough speech to verify?
            let accumulatedSamples = pendingBuffers.reduce(0) { $0 + Int($1.frameLength) }
            if accumulatedSamples >= minVerifySamples {
                await runVerification()
            } else if consecutiveSilentBuffers >= silenceBuffersToReset {
                // Window ended before we had enough audio to verify. Discard.
                log("VoiceIsolationGate: window too short to verify (\(accumulatedSamples) samples), dropping")
                pendingBuffers.removeAll(keepingCapacity: true)
                consecutiveSilentBuffers = 0
                state = .idle
            }

        case .streaming:
            // Verified user — pass audio straight through.
            try await inner.processAudio(buffer)
            if isSpeech {
                consecutiveSilentBuffers = 0
            } else {
                consecutiveSilentBuffers += 1
                if consecutiveSilentBuffers >= silenceBuffersToReset {
                    consecutiveSilentBuffers = 0
                    state = .idle
                    // Don't reset the inner provider here — it manages its own EOU
                    // and we want the trailing silence to count toward that.
                }
            }

        case .dropping:
            // We're discarding this window. Wait for silence to return to idle.
            if isSpeech {
                consecutiveSilentBuffers = 0
            } else {
                consecutiveSilentBuffers += 1
                if consecutiveSilentBuffers >= silenceBuffersToReset {
                    consecutiveSilentBuffers = 0
                    state = .idle
                }
            }
        }
    }

    func finish() async throws -> String? {
        return try await inner.finish()
    }

    func reset() async {
        pendingBuffers.removeAll(keepingCapacity: true)
        consecutiveSilentBuffers = 0
        state = .idle
        await inner.reset()
    }

    func cleanup() {
        inner.cleanup()
    }

    // MARK: - Verification

    private func runVerification() async {
        // Concatenate accumulated samples for the embedding extractor.
        var samples: [Float] = []
        samples.reserveCapacity(pendingBuffers.reduce(0) { $0 + Int($1.frameLength) })
        for buf in pendingBuffers {
            guard let channelData = buf.floatChannelData else { continue }
            let frameLength = Int(buf.frameLength)
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        guard let embedding = await extractor.extractDominantEmbedding(from: samples) else {
            // Couldn't extract — be conservative: drop this window.
            log("VoiceIsolationGate: extraction returned nil, dropping window")
            rejectedWindowsCount += 1
            pendingBuffers.removeAll(keepingCapacity: true)
            consecutiveSilentBuffers = 0
            state = .dropping
            return
        }

        let distance = VoiceEmbeddingExtractor.cosineDistance(embedding, enrolledEmbedding)
        log("VoiceIsolationGate: window verification distance=\(distance) threshold=\(threshold)")

        if distance <= threshold {
            verifiedWindowsCount += 1
            log("VoiceIsolationGate: VERIFIED (✓) — flushing \(pendingBuffers.count) buffered chunks")
            // Flush every buffered chunk to the inner provider in order.
            for buf in pendingBuffers {
                do {
                    try await inner.processAudio(buf)
                } catch {
                    log("VoiceIsolationGate: inner processAudio failed during flush: \(error.localizedDescription)")
                }
            }
            pendingBuffers.removeAll(keepingCapacity: true)
            consecutiveSilentBuffers = 0
            state = .streaming
        } else {
            rejectedWindowsCount += 1
            log("VoiceIsolationGate: REJECTED (✗) — dropping \(pendingBuffers.count) buffered chunks")
            pendingBuffers.removeAll(keepingCapacity: true)
            consecutiveSilentBuffers = 0
            // Reset the inner provider so any partial state from previous utterances
            // doesn't bleed into the next verified window.
            await inner.reset()
            state = .dropping
        }
    }

    // MARK: - Helpers

    /// Cheap RMS-based speech detector. Not a substitute for a real VAD model,
    /// but adequate to chunk audio into "speech windows" for verification.
    private func bufferIsSpeech(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData else { return false }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        var sumSquares: Float = 0
        let ptr = channelData[0]
        for i in 0..<frameLength {
            let s = ptr[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frameLength)).squareRoot()
        return rms >= speechRmsThreshold
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return buffer
        }
        copy.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frameLength * MemoryLayout<Float>.size)
            }
        }
        return copy
    }
}
