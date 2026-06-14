import Foundation
import AVFoundation
import Combine
import Accelerate

// Simple print-based logging for debugging
func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    print("[\(formatter.string(from: Date()))] [TranscriptionEngine] \(message)")
    fflush(stdout)
}

/// Thread-safe audio buffer queue using Swift actor
actor AudioBufferQueue {
    private var buffers: [AVAudioPCMBuffer] = []
    private let maxSize = 100 // Prevent unbounded growth

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        // Copy buffer data to prevent race conditions
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return
        }

        copy.frameLength = buffer.frameLength
        if let srcData = buffer.floatChannelData, let dstData = copy.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                memcpy(dstData[channel], srcData[channel], frameLength * MemoryLayout<Float>.size)
            }
        }

        if buffers.count < maxSize {
            buffers.append(copy)
        } else {
            // Drop oldest buffer if queue is full (prevents memory buildup)
            buffers.removeFirst()
            buffers.append(copy)
        }
    }

    func dequeue() -> AVAudioPCMBuffer? {
        guard !buffers.isEmpty else { return nil }
        return buffers.removeFirst()
    }

    func clear() {
        buffers.removeAll()
    }

    func count() -> Int {
        return buffers.count
    }
}

actor AudioProcessingState {
    private var inFlightCount = 0

    func beginBuffer() {
        inFlightCount += 1
    }

    func finishBuffer() {
        inFlightCount = max(0, inFlightCount - 1)
    }

    func count() -> Int {
        return inFlightCount
    }
}

/// Stores audio chunks for current utterance to enable batch re-processing
actor AudioChunkBuffer {
    private var currentUtteranceBuffers: [AVAudioPCMBuffer] = []
    private let format: AVAudioFormat

    init(format: AVAudioFormat) {
        self.format = format
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Copy buffer to prevent external modifications
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return
        }

        copy.frameLength = buffer.frameLength
        if let srcData = buffer.floatChannelData, let dstData = copy.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                memcpy(dstData[channel], srcData[channel], frameLength * MemoryLayout<Float>.size)
            }
        }

        currentUtteranceBuffers.append(copy)
    }

    func getAsSamples() -> [Float] {
        // Concatenate all buffers into a single Float array
        var allSamples: [Float] = []

        for buffer in currentUtteranceBuffers {
            guard let channelData = buffer.floatChannelData else { continue }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            allSamples.append(contentsOf: samples)
        }

        return allSamples
    }

    func clear() {
        currentUtteranceBuffers.removeAll()
    }

    func bufferCount() -> Int {
        return currentUtteranceBuffers.count
    }
}

/// Rolling audio buffer indexed by Deepgram-relative time. Time zero is anchored
/// to the moment the first audio buffer was successfully sent to the STT
/// provider — that's also Deepgram's t=0 for word-level timestamps. Each chunk
/// is tagged with its insertion offset so slicing matches Deepgram's timeline.
/// Capped at ~120 seconds to bound memory.
actor StreamAudioBuffer {
    private var samples: [Float] = []
    private var droppedSamples: Int = 0
    private let sampleRate: Int = 16000
    private let maxSeconds: Int = 120

    /// True once the first audio buffer has been appended after STT start.
    private var anchored = false

    func anchor() {
        anchored = true
        samples.removeAll()
        droppedSamples = 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard anchored else { return }  // ignore audio captured before Deepgram started
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        samples.append(contentsOf: chunk)
        let maxSamples = sampleRate * maxSeconds
        if samples.count > maxSamples {
            let drop = samples.count - maxSamples
            samples.removeFirst(drop)
            droppedSamples += drop
        }
    }

    /// Slice samples for [startSec, endSec] in Deepgram's timeline. Returns the
    /// requested window if still buffered, else empty.
    func slice(startSec: Double, endSec: Double) -> [Float] {
        guard endSec > startSec else { return [] }
        let absoluteStart = Int(startSec * Double(sampleRate))
        let absoluteEnd = Int(endSec * Double(sampleRate))
        let localStart = absoluteStart - droppedSamples
        let localEnd = absoluteEnd - droppedSamples
        guard localStart >= 0, localEnd <= samples.count, localEnd > localStart else { return [] }
        return Array(samples[localStart..<localEnd])
    }

    func totalBufferedSeconds() -> Double {
        return Double(samples.count + droppedSamples) / Double(sampleRate)
    }

    func reset() {
        samples.removeAll()
        droppedSamples = 0
        anchored = false
    }
}

/// Handles real-time streaming speech-to-text using pluggable STT backends
class TranscriptionEngine: ObservableObject {

    enum Status: Equatable {
        case initializing
        case downloadingModels
        case ready
        case listening
        case error(String)
    }

    @Published var status: Status = .initializing
    @Published var isSpeaking = false

    // Callbacks - called on main thread
    var onTranscription: ((String) -> Void)?           // Final text (on EOU)
    var onPartialTranscription: ((String) -> Void)?    // Ghost text (updates as you speak)
    var onLockedTextAdvanced: ((Int) -> Void)?         // Locked text length advanced (cloud backends)
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    var onUtteranceComplete: (([Float], String) -> Void)?  // Audio samples + streamed text for refinement

    // STT provider (local or cloud)
    private var sttProvider: STTProvider?
    private let backend: STTBackend

    // Audio capture (pluggable: MicAudioSource, SystemAudioSource, or MixedAudioSource)
    private var audioCaptureSource: AudioCaptureSource?

    // Track current partial for diffing
    private var currentPartial: String = ""

    // Most recent diarized runs for the current utterance, captured in onDiarizedFinal
    // and consumed by handleFinalTranscription to format the typed string. The
    // displayName field is non-nil when the hybrid diarizer overrode Deepgram's ID
    // with a stronger embedding match against an enrolled speaker.
    private var pendingDiarizedRuns: [(speakerId: Int, text: String, displayName: String?)]?

    // Hybrid diarization (local embedding override of Deepgram's IDs)
    private let speakerEmbedder = SpeakerEmbedder()
    /// Exposed so the enrollment UI can share the same loaded embedder instance.
    var publicSpeakerEmbedder: SpeakerEmbedder { speakerEmbedder }
    private lazy var hybridDiarizer = HybridDiarizer(embedder: speakerEmbedder)
    // Long-lived audio buffer indexed by Deepgram-relative time (zero = first
    // audio buffer successfully sent to the provider).
    private let streamAudioBuffer = StreamAudioBuffer()
    private var didAnchorStreamBuffer = false
    /// Task running the embedding override for the current utterance.
    /// `handleFinalTranscription` awaits this before consuming pendingDiarizedRuns
    /// so the typed text reflects the override decisions, not the raw Deepgram IDs.
    private var pendingOverrideTask: Task<Void, Never>?

    // Audio buffer queue - prevents race conditions without blocking audio thread
    private let audioBufferQueue = AudioBufferQueue()
    private let audioProcessingState = AudioProcessingState()
    private var processingTask: Task<Void, Never>?

    // Audio chunk buffer for batch re-processing (will be initialized after audio format is known)
    private var audioChunkBuffer: AudioChunkBuffer?
    private var isFinishingUtterance = false
    private var smoothedAudioLevel = 0.0
    private var lastAudioLevelPublishAt = Date.distantPast

    init(backend: STTBackend = .current) {
        self.backend = backend
        log("TranscriptionEngine initialized (backend: \(backend.rawValue))")
    }

    private func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log("Microphone auth status: \(status.rawValue)")

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    log("Microphone permission result: \(granted)")
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() async {
        await MainActor.run { status = .initializing }
        log("Starting TranscriptionEngine (backend: \(backend.rawValue))...")

        do {
            // Request microphone permission first
            log("Requesting microphone permission...")
            let granted = await requestMicrophonePermission()
            if !granted {
                await MainActor.run { status = .error("Microphone permission denied") }
                log("Microphone permission denied")
                return
            }
            log("Microphone permission granted")

            // Create and start the STT provider
            await MainActor.run { status = .downloadingModels }

            let provider = createProvider()

            // Wire up provider callbacks
            provider.onPartial = { [weak self] partial in
                self?.handlePartialTranscription(partial)
            }
            provider.onFinal = { [weak self] final in
                self?.handleFinalTranscription(final)
            }
            provider.onLockedTextAdvanced = { [weak self] lockedLen in
                // Called on main thread from provider — pass through directly
                self?.onLockedTextAdvanced?(lockedLen)
            }
            provider.onDiarizedFinal = { [weak self] runs in
                self?.handleDiarizedFinal(runs)
            }

            log("Starting STT provider...")
            try await provider.start()
            sttProvider = provider
            log("STT provider ready")

            // Setup audio capture
            let processingFormat = try await setupAudioCapture()

            // Initialize audio chunk buffer now that we know the format
            audioChunkBuffer = AudioChunkBuffer(format: processingFormat)

            // Start audio processing task
            startAudioProcessing()

            await MainActor.run { status = .ready }
            log("TranscriptionEngine ready!")

        } catch {
            await MainActor.run { status = .error(error.localizedDescription) }
            log("TranscriptionEngine error: \(error.localizedDescription)")
        }
    }

    private func createProvider() -> STTProvider {
        switch backend {
        case .local:
            log("Creating LocalSTTProvider (Nemotron)")
            return LocalSTTProvider()
        case .deepgram:
            let apiKey = APIKeyStore.get(for: .deepgram) ?? ""
            log("Creating DeepgramSTTProvider")
            return DeepgramSTTProvider(apiKey: apiKey)
        case .openAIRealtime:
            let apiKey = APIKeyStore.get(for: .openAIRealtime) ?? ""
            log("Creating OpenAIRealtimeSTTProvider")
            return OpenAIRealtimeSTTProvider(apiKey: apiKey)
        }
    }

    private func handlePartialTranscription(_ partial: String) {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        log("Partial: '\(trimmed)'")

        // Track speaking state
        if !isSpeaking {
            log("isSpeaking: false → true (speech started)")

            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = true
                self?.onSpeechStart?()
            }
        }

        // Update tracking
        currentPartial = trimmed

        DispatchQueue.main.async { [weak self] in
            self?.onPartialTranscription?(trimmed)
        }
    }

    private func handleDiarizedFinal(_ runs: [(speakerId: Int, text: String, startSec: Double, endSec: Double)]) {
        for run in runs { SpeakerLabelMap.recordSeen(run.speakerId) }

        // Default: store with no override.
        pendingDiarizedRuns = runs.map { (speakerId: $0.speakerId, text: $0.text, displayName: Optional<String>.none) }

        let enrolled = SpeakerRegistry.loadAll()
        guard !enrolled.isEmpty else { return }

        // Run override BEFORE handleFinalTranscription consumes pendingDiarizedRuns.
        // Both onDiarizedFinal and onFinal are dispatched to main in order, so we
        // need handleFinalTranscription to wait for the override result. We do
        // that by gating handleFinalTranscription on `pendingOverrideTask`, which
        // is set here and awaited there.
        let runsWithTiming = runs
        pendingOverrideTask = Task { [weak self] in
            guard let self = self else { return }
            let totalBuffered = await self.streamAudioBuffer.totalBufferedSeconds()
            HybridDiagLog.shared.write("--- new diarized final: \(runsWithTiming.count) runs, buffer=\(String(format: "%.2f", totalBuffered))s ---")
            var withAudio: [DiarizedRunWithAudio] = []
            for run in runsWithTiming {
                let samples = await self.streamAudioBuffer.slice(startSec: run.startSec, endSec: run.endSec)
                let gotSec = Double(samples.count) / 16000.0
                let askSec = run.endSec - run.startSec
                HybridDiagLog.shared.write("  run dgId=\(run.speakerId) ask=[\(String(format: "%.2f", run.startSec))→\(String(format: "%.2f", run.endSec))] askDur=\(String(format: "%.2f", askSec))s gotSamples=\(samples.count) gotDur=\(String(format: "%.2f", gotSec))s text='\(run.text.prefix(60))'")
                withAudio.append(DiarizedRunWithAudio(
                    deepgramSpeakerId: run.speakerId,
                    text: run.text,
                    samples: samples
                ))
            }
            let overridden = await self.hybridDiarizer.override(runs: withAudio, enrolled: enrolled)
            await MainActor.run {
                self.pendingDiarizedRuns = overridden.map { (speakerId: $0.deepgramSpeakerId, text: $0.text, displayName: $0.enrolledName) }
            }
        }
    }

    /// Format speaker attribution as an append-only suffix. The plain utterance
    /// has already streamed into the destination, so final diarization must not
    /// rewrite the beginning of that text.
    private func formatSpeakerSuffix(_ runs: [(speakerId: Int, text: String, displayName: String?)]) -> String {
        var labels: [String] = []
        var lastLabel: String? = nil
        for run in runs {
            let trimmedRun = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRun.isEmpty else { continue }
            let label = run.displayName ?? SpeakerLabelMap.name(forSpeakerId: run.speakerId)
            if label != lastLabel {
                labels.append(label)
                lastLabel = label
            }
        }

        guard !labels.isEmpty else { return "" }
        let speakerLine = "\n[\(labels.joined(separator: " -> "))]"
        let willSubmitUtterance = UserDefaults.standard.bool(forKey: "pressEnterAfterSpeech")
        return willSubmitUtterance ? speakerLine : "\(speakerLine)\n\n"
    }

    private func handleFinalTranscription(_ final: String) {
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        log("Final (EOU): '\(trimmed)'")

        // Wait for the embedding override to land (if any) so the typed text
        // reflects the corrected speaker labels, not the raw Deepgram IDs.
        let overrideTask = pendingOverrideTask
        pendingOverrideTask = nil

        Task { [weak self] in
            if let overrideTask = overrideTask {
                _ = await overrideTask.value
            }
            await MainActor.run { [weak self] in
                self?.emitFinalTranscription(trimmed)
            }
        }
    }

    /// Actual emission path — runs after the override task (if any) has settled.
    @MainActor
    private func emitFinalTranscription(_ trimmed: String) {
        // If diarization labeling is enabled and we have runs from the matching
        // onDiarizedFinal, append speaker attribution after the already-streamed
        // utterance instead of rewriting a prefix into the beginning.
        var emittedText = trimmed
        if SpeakerLabelMap.enabled, let runs = pendingDiarizedRuns, !runs.isEmpty {
            let suffix = formatSpeakerSuffix(runs)
            if !suffix.isEmpty {
                emittedText += suffix
                log("Final (speaker suffix): '\(suffix)'")
            }
        }
        pendingDiarizedRuns = nil

        // Reset partial tracking
        currentPartial = ""

        // Get audio samples for batch refinement (if enabled and backend is local)
        Task {
            let audioSamples = await audioChunkBuffer?.getAsSamples() ?? []
            let bufferCount = await audioChunkBuffer?.bufferCount() ?? 0

            if !audioSamples.isEmpty {
                let duration = Float(audioSamples.count) / 16000.0
                log("Captured \(bufferCount) audio chunks (\(String(format: "%.1f", duration))s) for utterance")
            } else if !backend.returnsPunctuatedText {
                log("Warning: No audio samples captured for utterance")
            }

            DispatchQueue.main.async { [weak self] in
                if !emittedText.isEmpty {
                    self?.onTranscription?(emittedText)

                    // Only provide audio for refinement if backend doesn't already punctuate
                    if !(self?.backend.returnsPunctuatedText ?? true) && !audioSamples.isEmpty {
                        self?.onUtteranceComplete?(audioSamples, emittedText)
                    }
                }

                log("isSpeaking: true → false (speech ended)")
                self?.isSpeaking = false
                self?.resetAudioLevel()
                self?.onSpeechEnd?()
            }

            // Clear audio chunk buffer AFTER refinement callback
            await audioChunkBuffer?.clear()
            log("Audio chunk buffer cleared")

            // Reset the provider for next utterance
            await sttProvider?.reset()
        }
    }

    func startCapture() {
        switch status {
        case .ready, .listening:
            break
        default:
            log("Cannot start listening - status is \(String(describing: self.status))")
            return
        }

        // The AudioCaptureSource is already running from setupAudioCapture(),
        // since SCStream / AVAudioEngine both want to be started once and
        // outlive the listening on/off toggle. We just flip status here.
        status = .listening
        log("Listening started")
    }

    func stopCapture() {
        // Hard stop the source; will be re-created on next start cycle.
        audioCaptureSource?.stop()
        audioCaptureSource = nil
        status = .ready
        didAnchorStreamBuffer = false
        resetAudioLevel()
        Task { await streamAudioBuffer.reset() }
        log("Listening stopped")
    }

    func finishCurrentUtterance() async {
        guard !isFinishingUtterance else { return }
        isFinishingUtterance = true
        defer { isFinishingUtterance = false }

        await drainAudioQueue()

        guard let provider = sttProvider else { return }

        let final = try? await provider.finishCurrentUtterance()
        if let text = final, !text.isEmpty {
            handleFinalTranscription(text)
        } else {
            await audioChunkBuffer?.clear()
            await provider.reset()

            if isSpeaking {
                DispatchQueue.main.async { [weak self] in
                    log("isSpeaking: true → false (speech ended)")
                    self?.isSpeaking = false
                    self?.resetAudioLevel()
                    self?.onSpeechEnd?()
                }
            }
        }
    }

    func startListening() {
        startCapture()
    }

    func stopListening() {
        stopCapture()
        Task {
            await finishCurrentUtterance()
        }
    }

    private func setupAudioCapture() async throws -> AVAudioFormat {
        log("Setting up audio capture...")

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "TranscriptionEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }

        let captureSystemAudio = UserDefaults.standard.bool(forKey: "captureSystemAudio")
        let source: AudioCaptureSource
        if captureSystemAudio {
            if #available(macOS 13.0, *) {
                log("Audio capture mode: MIXED (mic + system audio via ScreenCaptureKit)")
                source = MixedAudioSource(mic: MicAudioSource(), system: SystemAudioSource())
            } else {
                log("System audio capture requires macOS 13 or newer; falling back to MIC only")
                source = MicAudioSource()
            }
        } else {
            log("Audio capture mode: MIC only")
            source = MicAudioSource()
        }

        try await source.start { [weak self] buffer in
            self?.handleCapturedBuffer(buffer)
        }

        self.audioCaptureSource = source
        log("Audio capture setup complete")
        return processingFormat
    }

    private var audioChunkCount = 0

    /// Receives 16kHz mono Float32 buffers from whichever AudioCaptureSource is
    /// active. Buffers are already in the target format, so no conversion is
    /// needed here — just enqueue.
    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        audioChunkCount += 1
        if audioChunkCount % 50 == 0 {
            log("Audio chunk #\(audioChunkCount), frames: \(buffer.frameLength)")
        }
        updateAudioLevel(from: buffer)
        Task {
            await audioBufferQueue.enqueue(buffer)
        }
    }

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        let targetLevel = status == .listening ? measuredAudioLevel(from: buffer) : 0
        let coefficient = targetLevel > smoothedAudioLevel ? 0.45 : 0.18
        smoothedAudioLevel += (targetLevel - smoothedAudioLevel) * coefficient

        if targetLevel == 0, smoothedAudioLevel < 0.015 {
            smoothedAudioLevel = 0
        }

        let now = Date()
        guard now.timeIntervalSince(lastAudioLevelPublishAt) >= 0.033 || smoothedAudioLevel == 0 else {
            return
        }

        lastAudioLevelPublishAt = now
        let level = smoothedAudioLevel
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
        }
    }

    private func measuredAudioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))
        guard rms.isFinite, rms > 0 else { return 0 }

        let decibels = 20.0 * log10(Double(rms))
        let noiseFloor = -50.0
        let loudSpeech = -18.0
        let normalized = (decibels - noiseFloor) / (loudSpeech - noiseFloor)
        let clamped = min(1.0, max(0.0, normalized))

        if clamped < 0.06 {
            return 0
        }

        return pow(clamped, 1.25)
    }

    private func resetAudioLevel() {
        smoothedAudioLevel = 0
        lastAudioLevelPublishAt = Date.distantPast
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(0)
        }
    }

    private func startAudioProcessing() {
        processingTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Dequeue and process buffers serially
                if let buffer = await self.audioBufferQueue.dequeue() {
                    await self.audioProcessingState.beginBuffer()

                    do {
                        try await self.sttProvider?.processAudio(buffer)

                        // FIX: Always save audio chunks for batch refinement (unconditional)
                        // This ensures we capture the complete utterance from the beginning,
                        // not just after isSpeaking flag is set (which happens after first partial arrives)
                        await self.audioChunkBuffer?.append(buffer)

                        // Anchor the stream buffer to Deepgram's t=0 (the moment the
                        // first audio chunk was successfully sent). Then append.
                        if !self.didAnchorStreamBuffer {
                            self.didAnchorStreamBuffer = true
                            await self.streamAudioBuffer.anchor()
                            HybridDiagLog.shared.write("StreamAudioBuffer anchored — first audio sent to Deepgram")
                        }
                        await self.streamAudioBuffer.append(buffer)
                    } catch {
                        log("STT process error: \(error.localizedDescription)")
                    }

                    await self.audioProcessingState.finishBuffer()
                } else {
                    // No buffers available, wait a bit
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                }
            }
        }
    }

    private func stopAudioProcessing() {
        processingTask?.cancel()
        processingTask = nil
        Task {
            await audioBufferQueue.clear()
        }
    }

    private func drainAudioQueue(timeoutNanoseconds: UInt64 = 400_000_000) async {
        let start = DispatchTime.now().uptimeNanoseconds

        while true {
            let queuedBufferCount = await audioBufferQueue.count()
            let inFlightBufferCount = await audioProcessingState.count()
            if queuedBufferCount == 0 && inFlightBufferCount == 0 {
                break
            }

            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                log("Audio queue drain timed out")
                break
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func cleanup() {
        stopCapture()
        stopAudioProcessing()
        sttProvider?.cleanup()
        sttProvider = nil
        log("TranscriptionEngine cleaned up")
    }
}
