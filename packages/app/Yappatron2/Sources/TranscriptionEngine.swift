import Foundation
import FluidAudio
import AVFoundation
import Combine

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
    private var lastProcessedSampleCount: Int = 0
    private let chunkDurationSeconds: Double = 0.8 // Process every 800ms
    
    // Simple energy-based VAD
    private var speechStartTime: Date?
    private var lastSpeechTime: Date?
    private let silenceTimeout: TimeInterval = 1.0 // 1 second of silence = end of speech
    private let speechThreshold: Float = 0.01 // Energy threshold for speech detection
    
    init() {}
    
    func start() async {
        await MainActor.run { status = .initializing }
        
        do {
            // Download and load ASR models (English v2 for best accuracy)
            await MainActor.run { status = .downloadingModels }
            NSLog("[TranscriptionEngine] Downloading models...")
            models = try await AsrModels.downloadAndLoad(version: .v2)
            
            // Initialize ASR Manager
            NSLog("[TranscriptionEngine] Initializing ASR manager...")
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models!)
            asrManager = manager
            
            // Setup audio capture
            try await setupAudioCapture()
            
            await MainActor.run { status = .ready }
            NSLog("[TranscriptionEngine] Ready")
            
        } catch {
            await MainActor.run { status = .error(error.localizedDescription) }
            NSLog("[TranscriptionEngine] Error: %@", error.localizedDescription)
        }
    }
    
    func startListening() {
        // Allow starting if ready OR already listening
        switch status {
        case .ready, .listening:
            break
        default:
            return
        }
        
        do {
            try audioEngine?.start()
            status = .listening
            startStreamingTranscription()
            NSLog("[TranscriptionEngine] Listening started")
        } catch {
            status = .error(error.localizedDescription)
        }
    }
    
    func stopListening() {
        streamingTask?.cancel()
        streamingTask = nil
        audioEngine?.stop()
        status = .ready
        NSLog("[TranscriptionEngine] Listening stopped")
    }
    
    private func setupAudioCapture() async throws {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode
        
        guard let inputNode = inputNode else {
            throw NSError(domain: "TranscriptionEngine", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // FluidAudio expects 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16000,
                                                channels: 1,
                                                interleaved: false) else {
            throw NSError(domain: "TranscriptionEngine", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Could not create target format"])
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "TranscriptionEngine", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Convert to 16kHz mono
            let ratio = 16000.0 / inputFormat.sampleRate
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                          frameCapacity: frameCount) else { return }
            
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .haveData || status == .inputRanDry {
                guard let channelData = convertedBuffer.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                
                // Thread-safe append to buffer
                self.audioBufferLock.lock()
                self.audioBuffer.append(contentsOf: samples)
                self.audioBufferLock.unlock()
                
                // Check for speech using energy
                let energy = samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)
                if energy > self.speechThreshold {
                    self.handleSpeechDetected()
                }
            }
        }
        
        audioEngine?.prepare()
    }
    
    private func handleSpeechDetected() {
        let now = Date()
        
        if !isSpeaking {
            // Speech started
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = true
                self?.onSpeechStart?()
            }
            speechStartTime = now
        }
        
        lastSpeechTime = now
    }
    
    private func startStreamingTranscription() {
        streamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(0.8 * 1_000_000_000)) // 800ms
                await self?.processAudioChunk()
            }
        }
    }
    
    private func processAudioChunk() async {
        // Check for silence timeout (end of speech)
        if isSpeaking, let lastSpeech = lastSpeechTime {
            if Date().timeIntervalSince(lastSpeech) > silenceTimeout {
                // Speech ended - transcribe accumulated audio
                await transcribeAndEmit()
                
                await MainActor.run { [weak self] in
                    self?.isSpeaking = false
                    self?.onSpeechEnd?()
                }
                return
            }
        }
        
        // Don't process if not speaking
        guard isSpeaking else { return }
    }
    
    private func transcribeAndEmit() async {
        // Get samples from buffer
        audioBufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        audioBufferLock.unlock()
        
        guard !samples.isEmpty else { return }
        
        do {
            guard let manager = asrManager else { return }
            
            let result = try await manager.transcribe(samples, source: .microphone)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !text.isEmpty {
                await MainActor.run { [weak self] in
                    self?.onTranscription?(text)
                }
            }
            
        } catch {
            NSLog("[TranscriptionEngine] Transcription error: %@", error.localizedDescription)
        }
    }
    
    func cleanup() {
        stopListening()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        asrManager = nil
    }
}
