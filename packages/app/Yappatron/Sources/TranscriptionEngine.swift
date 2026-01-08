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

/// Handles real-time streaming speech-to-text using FluidAudio's StreamingEouAsrManager
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
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    
    // Streaming ASR
    private var streamingManager: StreamingEouAsrManager?
    
    // Audio capture
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    // Track current partial for diffing
    private var currentPartial: String = ""
    
    init() {
        log("TranscriptionEngine initialized")
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
        log("Starting TranscriptionEngine (streaming mode)...")
        
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
            
            // Download streaming models
            await MainActor.run { status = .downloadingModels }
            log("Downloading streaming models...")
            
            let modelDir = try await downloadStreamingModels()
            log("Models downloaded to: \(modelDir.path)")
            
            // Initialize StreamingEouAsrManager
            log("Initializing StreamingEouAsrManager...")
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            
            let manager = StreamingEouAsrManager(
                configuration: config,
                chunkSize: .ms160,      // 160ms chunks for lowest latency
                eouDebounceMs: 800      // 800ms silence to confirm end (was 1280)
            )
            
            try await manager.loadModels(modelDir: modelDir)
            
            // Set up callbacks
            await manager.setPartialCallback { [weak self] partial in
                self?.handlePartialTranscription(partial)
            }
            
            await manager.setEouCallback { [weak self] final in
                self?.handleFinalTranscription(final)
            }
            
            streamingManager = manager
            log("StreamingEouAsrManager initialized")
            
            // Setup audio capture
            try setupAudioCapture()
            
            await MainActor.run { status = .ready }
            log("TranscriptionEngine ready (streaming mode)!")
            
        } catch {
            await MainActor.run { status = .error(error.localizedDescription) }
            log("TranscriptionEngine error: \(error.localizedDescription)")
        }
    }
    
    private func downloadStreamingModels() async throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let modelPath = modelsDir.appendingPathComponent(Repo.parakeetEou160.folderName)
        
        // Check if models already exist (just check for streaming_encoder)
        let encoderPath = modelPath.appendingPathComponent("streaming_encoder.mlmodelc")
        if FileManager.default.fileExists(atPath: encoderPath.path) {
            log("Streaming models already cached")
            return modelPath
        }
        
        // Download the 160ms streaming models - only request what we actually need
        // (vocab.json is used, not tokenizer.model)
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
    
    private func handlePartialTranscription(_ partial: String) {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        log("Partial: '\(trimmed)'")
        
        // Track speaking state
        if !isSpeaking {
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
        
        DispatchQueue.main.async { [weak self] in
            if !trimmed.isEmpty {
                self?.onTranscription?(trimmed)
            }
            self?.isSpeaking = false
            self?.onSpeechEnd?()
        }
        
        // Reset the streaming manager for next utterance
        Task {
            await streamingManager?.reset()
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
            log("Listening started (streaming)")
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
            if let manager = streamingManager {
                let final = try? await manager.finish()
                if let text = final, !text.isEmpty {
                    handleFinalTranscription(text)
                }
                await manager.reset()
            }
        }
        
        log("Listening stopped")
    }
    
    private func setupAudioCapture() throws {
        log("Setting up audio capture...")
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode
        
        guard let inputNode = inputNode else {
            throw NSError(domain: "TranscriptionEngine", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        log("Input format: \(inputFormat.channelCount) channels, \(inputFormat.sampleRate) Hz")
        
        // Create format for streaming manager (16kHz mono)
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
        
        // Feed to streaming manager
        Task {
            do {
                _ = try await streamingManager?.process(audioBuffer: outputBuffer)
            } catch {
                log("Streaming process error: \(error.localizedDescription)")
            }
        }
    }
    
    func cleanup() {
        stopListening()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        streamingManager = nil
        log("TranscriptionEngine cleaned up")
    }
}
