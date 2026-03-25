import Foundation
import FluidAudio
import AVFoundation
import Combine
import Accelerate
import CoreML

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
    var onUtteranceComplete: (([Float], String) -> Void)?  // Audio samples + streamed text for refinement

    // STT provider (local or cloud)
    private var sttProvider: STTProvider?
    private let backend: STTBackend

    // Audio capture
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // Track current partial for diffing
    private var currentPartial: String = ""

    // Audio buffer queue - prevents race conditions without blocking audio thread
    private let audioBufferQueue = AudioBufferQueue()
    private var processingTask: Task<Void, Never>?

    // Audio chunk buffer for batch re-processing (will be initialized after audio format is known)
    private var audioChunkBuffer: AudioChunkBuffer?

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
                DispatchQueue.main.async {
                    self?.onLockedTextAdvanced?(lockedLen)
                }
            }

            log("Starting STT provider...")
            try await provider.start()
            sttProvider = provider
            log("STT provider ready")

            // Setup audio capture
            let processingFormat = try setupAudioCapture()

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
            log("Creating LocalSTTProvider (Parakeet)")
            return LocalSTTProvider()
        case .deepgram:
            let apiKey = APIKeyStore.get(for: .deepgram) ?? ""
            log("Creating DeepgramSTTProvider")
            return DeepgramSTTProvider(apiKey: apiKey)
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

    private func handleFinalTranscription(_ final: String) {
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        log("Final (EOU): '\(trimmed)'")

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
                if !trimmed.isEmpty {
                    self?.onTranscription?(trimmed)

                    // Only provide audio for refinement if backend doesn't already punctuate
                    if !(self?.backend.returnsPunctuatedText ?? true) && !audioSamples.isEmpty {
                        self?.onUtteranceComplete?(audioSamples, trimmed)
                    }
                }

                log("isSpeaking: true → false (speech ended)")
                self?.isSpeaking = false
                self?.onSpeechEnd?()
            }

            // Clear audio chunk buffer AFTER refinement callback
            await audioChunkBuffer?.clear()
            log("Audio chunk buffer cleared")

            // Reset the provider for next utterance
            await sttProvider?.reset()
        }
    }

    func startListening() {
        switch status {
        case .ready, .listening:
            break
        default:
            log("Cannot start listening - status is \(String(describing: self.status))")
            return
        }

        do {
            try audioEngine?.start()
            status = .listening
            log("Listening started")
        } catch {
            status = .error(error.localizedDescription)
            log("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    func stopListening() {
        audioEngine?.stop()
        status = .ready

        // Finish any pending transcription
        Task {
            if let provider = sttProvider {
                let final = try? await provider.finish()
                if let text = final, !text.isEmpty {
                    handleFinalTranscription(text)
                }
                await provider.reset()
            }
        }

        log("Listening stopped")
    }

    private func setupAudioCapture() throws -> AVAudioFormat {
        log("Setting up audio capture...")
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode

        guard let inputNode = inputNode else {
            throw NSError(domain: "TranscriptionEngine", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        log("Input format: \(inputFormat.channelCount) channels, \(inputFormat.sampleRate) Hz")

        // Create format for processing (16kHz mono)
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "TranscriptionEngine", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }

        // Install tap and convert to 16kHz
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, inputFormat: inputFormat, outputFormat: processingFormat)
        }

        audioEngine?.prepare()
        log("Audio capture setup complete")
        return processingFormat
    }

    private var audioChunkCount = 0

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        // Convert to 16kHz mono using AVAudioConverter
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            log("Failed to create audio converter")
            return
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            log("Failed to create output buffer")
            return
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            log("Conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        audioChunkCount += 1
        if audioChunkCount % 50 == 0 {
            log("Audio chunk #\(audioChunkCount), frames: \(outputBuffer.frameLength)")
        }

        // Enqueue buffer for processing (non-blocking)
        Task {
            await audioBufferQueue.enqueue(outputBuffer)
        }
    }

    private func startAudioProcessing() {
        processingTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Dequeue and process buffers serially
                if let buffer = await self.audioBufferQueue.dequeue() {
                    do {
                        try await self.sttProvider?.processAudio(buffer)

                        // FIX: Always save audio chunks for batch refinement (unconditional)
                        // This ensures we capture the complete utterance from the beginning,
                        // not just after isSpeaking flag is set (which happens after first partial arrives)
                        await self.audioChunkBuffer?.append(buffer)
                    } catch {
                        log("STT process error: \(error.localizedDescription)")
                    }
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

    func cleanup() {
        stopListening()
        stopAudioProcessing()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        sttProvider?.cleanup()
        sttProvider = nil
        log("TranscriptionEngine cleaned up")
    }
}
