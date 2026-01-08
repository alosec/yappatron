import Foundation
import FluidAudio
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

/// Handles real-time speech-to-text using FluidAudio's Parakeet model
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
    var onTranscription: ((String) -> Void)?
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    
    // FluidAudio components
    private var asrManager: AsrManager?
    private var models: AsrModels?
    
    // Audio capture
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    // Thread-safe audio buffer
    private let audioBufferLock = NSLock()
    private var audioBuffer: [Float] = []
    
    // Streaming transcription
    private var streamingTask: Task<Void, Never>?
    
    // Simple energy-based VAD
    private var speechStartTime: Date?
    private var lastSpeechTime: Date?
    private let silenceTimeout: TimeInterval = 1.2 // 1.2 seconds of silence = end of speech
    private let speechThreshold: Float = 0.015 // RMS threshold for speech detection (adjusted for typical room noise)
    
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
        log("Starting TranscriptionEngine...")
        
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
            
            // Download and load ASR models (English v2 for best accuracy)
            await MainActor.run { status = .downloadingModels }
            log("Downloading models...")
            models = try await AsrModels.downloadAndLoad(version: .v2)
            log("Models downloaded")
            
            // Initialize ASR Manager
            log("Initializing ASR manager...")
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models!)
            asrManager = manager
            log("ASR manager initialized")
            
            // Setup audio capture
            try setupAudioCapture()
            
            await MainActor.run { status = .ready }
            log("TranscriptionEngine ready!")
            
        } catch {
            await MainActor.run { status = .error(error.localizedDescription) }
            log("TranscriptionEngine error: \(error.localizedDescription)")
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
            startStreamingTranscription()
            log("Listening started")
        } catch {
            status = .error(error.localizedDescription)
            log("Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    func stopListening() {
        streamingTask?.cancel()
        streamingTask = nil
        audioEngine?.stop()
        status = .ready
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
        
        // Install tap - we'll do our own resampling
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
        }
        
        audioEngine?.prepare()
        log("Audio capture setup complete")
    }
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Convert to mono 16kHz
        let samples = toMono16k(buffer: buffer)
        guard !samples.isEmpty else { return }
        
        // Calculate RMS for VAD
        var sum: Float = 0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))
        
        // Log occasionally
        if Int.random(in: 0..<30) == 0 {
            log("Audio RMS: \(rms), threshold: \(speechThreshold), speaking: \(isSpeaking)")
        }
        
        // Only accumulate audio when speaking
        if rms > speechThreshold {
            // Speech detected - accumulate samples and update timestamp
            audioBufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            audioBufferLock.unlock()
            
            handleSpeechDetected()
        } else if isSpeaking {
            // Below threshold but still in speech segment - accumulate for a bit
            // (captures trailing audio)
            audioBufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            audioBufferLock.unlock()
        }
    }
    
    private func toMono16k(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sourceSampleRate = buffer.format.sampleRate
        
        // Downmix to mono
        var mono: [Float]
        if channelCount == 1 {
            mono = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            mono = [Float](repeating: 0, count: frameCount)
            for c in 0..<channelCount {
                let src = channelData[c]
                vDSP_vadd(src, 1, mono, 1, &mono, 1, vDSP_Length(frameCount))
            }
            var div = Float(channelCount)
            vDSP_vsdiv(mono, 1, &div, &mono, 1, vDSP_Length(frameCount))
        }
        
        // Resample to 16kHz if needed
        if sourceSampleRate != 16000.0 {
            let ratio = 16000.0 / sourceSampleRate
            let outCount = Int(Double(mono.count) * ratio)
            var output = [Float](repeating: 0, count: outCount)
            
            for i in 0..<outCount {
                let srcPos = Double(i) / ratio
                let idx = Int(srcPos)
                let frac = Float(srcPos - Double(idx))
                if idx + 1 < mono.count {
                    output[i] = mono[idx] + (mono[idx + 1] - mono[idx]) * frac
                } else if idx < mono.count {
                    output[i] = mono[idx]
                }
            }
            return output
        }
        
        return mono
    }
    
    private func handleSpeechDetected() {
        let now = Date()
        
        if !isSpeaking {
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = true
                self?.onSpeechStart?()
            }
            speechStartTime = now
            log("Speech started")
        }
        
        lastSpeechTime = now
    }
    
    private func startStreamingTranscription() {
        streamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000)) // 500ms
                await self?.processAudioChunk()
            }
        }
    }
    
    private func processAudioChunk() async {
        // Check for silence timeout (end of speech)
        if isSpeaking, let lastSpeech = lastSpeechTime {
            if Date().timeIntervalSince(lastSpeech) > silenceTimeout {
                log("Speech ended (silence timeout)")
                await transcribeAndEmit()
                
                await MainActor.run { [weak self] in
                    self?.isSpeaking = false
                    self?.onSpeechEnd?()
                }
            }
        }
    }
    
    private func transcribeAndEmit() async {
        // Get samples from buffer
        audioBufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)
        audioBufferLock.unlock()
        
        guard samples.count > 1600 else { // At least 100ms of audio
            log("Not enough samples to transcribe: \(samples.count)")
            return
        }
        
        log("Transcribing \(samples.count) samples (\(Double(samples.count) / 16000.0) seconds)...")
        
        do {
            guard let manager = asrManager else {
                log("ASR manager not initialized")
                return
            }
            
            let result = try await manager.transcribe(samples, source: .microphone)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            log("Transcription: '\(text)' (confidence: \(result.confidence))")
            
            if !text.isEmpty {
                await MainActor.run { [weak self] in
                    self?.onTranscription?(text)
                }
            }
            
        } catch {
            log("Transcription error: \(error.localizedDescription)")
        }
    }
    
    func cleanup() {
        stopListening()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        asrManager = nil
        log("TranscriptionEngine cleaned up")
    }
}
