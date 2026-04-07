import AVFoundation
import Foundation

/// Decorator over an STTProvider that runs each speech window through a
/// SpeakerDecision before letting audio reach the inner provider.
///
/// The gate is mode-agnostic — isolation, capture, and meeting modes are
/// expressed by passing a different SpeakerDecision implementation. The state
/// machine, the energy VAD, and the buffer-then-flush semantics are shared.
///
/// State machine:
///
///   idle ──speech──▶ accumulating ──≥1s of speech──▶ verify
///    ▲                    │                              │
///    │                    └──silence (too short)─────────┤
///    │                                                   │
///    │                                       ┌──allow────┘
///    │                                       │
///    │                                       ▼
///    │                                   streaming ──silence──▶ idle
///    │                                       │
///    │                                       └──extended silence──▶ idle
///    │                                                   │
///    │                                       ┌──deny─────┘
///    │                                       │
///    │                                       ▼
///    └──silence────────────────────────── dropping
///
/// Properties:
/// - When the decision is .allow, the *entire* buffered window is flushed to
///   the inner provider in order, so the user's first words appear intact
///   (delayed by ~1s on the first utterance of a window).
/// - When the decision is .deny or .captureUnknown, the inner provider sees
///   nothing, and reset() is called on the inner provider to clear partial state.
/// - When .captureUnknown is returned, the gate writes a new "Unknown N" entry
///   to the SpeakerRegistry and posts an OS notification via `onCapturedUnknown`.
final class VoiceIsolationGate: STTProvider, @unchecked Sendable {

    // MARK: STTProvider conformance
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLockedTextAdvanced: ((Int) -> Void)?
    var onSpeakerLabel: ((String) -> Void)?

    // MARK: Dependencies
    private let inner: STTProvider
    private let extractor: VoiceEmbeddingExtractor
    private var decision: SpeakerDecision

    /// Called on the main thread whenever a new Unknown speaker is captured.
    /// The handler typically posts a UNNotification and may update menu state.
    var onCapturedUnknown: ((RegisteredSpeaker) -> Void)?

    // MARK: State machine
    private enum State {
        case idle
        case accumulating
        case streaming
        case dropping
    }
    private var state: State = .idle

    // MARK: Tunables
    private let sampleRate: Double = 16000
    private let speechRmsThreshold: Float = 0.005
    private var minVerifySamples: Int { Int(sampleRate * 1.0) }
    private let silenceBuffersToReset: Int = 8  // ~256ms * 8 ≈ 2s
    private var consecutiveSilentBuffers: Int = 0

    private var pendingBuffers: [AVAudioPCMBuffer] = []

    // MARK: Stats
    private(set) var verifiedWindowsCount: Int = 0
    private(set) var rejectedWindowsCount: Int = 0
    private(set) var capturedUnknownCount: Int = 0

    // MARK: Init

    init(
        inner: STTProvider,
        extractor: VoiceEmbeddingExtractor,
        decision: SpeakerDecision
    ) {
        self.inner = inner
        self.extractor = extractor
        self.decision = decision

        self.inner.onPartial = { [weak self] partial in self?.onPartial?(partial) }
        self.inner.onFinal = { [weak self] final in self?.onFinal?(final) }
        self.inner.onLockedTextAdvanced = { [weak self] len in self?.onLockedTextAdvanced?(len) }

        log("VoiceIsolationGate: ready (decision=\(type(of: decision)))")
    }

    /// Hot-swap the decision policy. Used when toggling between isolation,
    /// capture, and meeting mode without restarting the provider.
    func setDecision(_ newDecision: SpeakerDecision) {
        self.decision = newDecision
        log("VoiceIsolationGate: decision swapped to \(type(of: newDecision))")
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

        case .accumulating:
            pendingBuffers.append(copyBuffer(buffer))
            if isSpeech {
                consecutiveSilentBuffers = 0
            } else {
                consecutiveSilentBuffers += 1
            }

            let accumulatedSamples = pendingBuffers.reduce(0) { $0 + Int($1.frameLength) }
            if accumulatedSamples >= minVerifySamples {
                await runVerification()
            } else if consecutiveSilentBuffers >= silenceBuffersToReset {
                log("VoiceIsolationGate: window too short to verify (\(accumulatedSamples) samples), dropping")
                pendingBuffers.removeAll(keepingCapacity: true)
                consecutiveSilentBuffers = 0
                state = .idle
            }

        case .streaming:
            try await inner.processAudio(buffer)
            if isSpeech {
                consecutiveSilentBuffers = 0
            } else {
                consecutiveSilentBuffers += 1
                if consecutiveSilentBuffers >= silenceBuffersToReset {
                    consecutiveSilentBuffers = 0
                    state = .idle
                }
            }

        case .dropping:
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
        let totalSamples = pendingBuffers.reduce(0) { $0 + Int($1.frameLength) }
        var samples: [Float] = []
        samples.reserveCapacity(totalSamples)
        for buf in pendingBuffers {
            guard let channelData = buf.floatChannelData else { continue }
            let frameLength = Int(buf.frameLength)
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        guard let embedding = await extractor.extractDominantEmbedding(from: samples) else {
            log("VoiceIsolationGate: extraction returned nil, dropping window")
            rejectedWindowsCount += 1
            await dropPending()
            state = .dropping
            return
        }

        let speechDuration = Float(samples.count) / Float(sampleRate)
        let outcome = decision.decide(embedding: embedding, speechDuration: speechDuration)

        switch outcome {
        case .allow(let speakerId, let name):
            verifiedWindowsCount += 1
            log("VoiceIsolationGate: ALLOW (\(name), id=\(speakerId)) — flushing \(pendingBuffers.count) chunks")

            // Notify listeners about the speaker label *before* flushing audio
            // so meeting-mode UIs can group the upcoming text correctly.
            DispatchQueue.main.async { [weak self] in
                self?.onSpeakerLabel?(name)
            }

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

        case .deny:
            rejectedWindowsCount += 1
            log("VoiceIsolationGate: DENY — dropping \(pendingBuffers.count) chunks")
            await dropPending()
            state = .dropping

        case .captureUnknown(let unknownEmbedding):
            capturedUnknownCount += 1
            let name = SpeakerRegistry.nextUnknownName()
            let captured = RegisteredSpeaker(
                id: UUID().uuidString,
                name: name,
                embedding: unknownEmbedding,
                allowed: false,
                source: .autoCaptured,
                createdAt: Date(),
                updatedAt: Date()
            )
            do {
                try SpeakerRegistry.upsert(captured)
                log("VoiceIsolationGate: CAPTURED unknown as '\(name)'")
                DispatchQueue.main.async { [weak self] in
                    self?.onCapturedUnknown?(captured)
                }
            } catch {
                log("VoiceIsolationGate: failed to persist captured unknown: \(error.localizedDescription)")
            }
            await dropPending()
            state = .dropping
        }
    }

    private func dropPending() async {
        pendingBuffers.removeAll(keepingCapacity: true)
        consecutiveSilentBuffers = 0
        await inner.reset()
    }

    // MARK: - Helpers

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
