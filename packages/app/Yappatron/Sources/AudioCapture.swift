import Foundation
import AVFoundation
import Accelerate

/// Status of audio capture
enum AudioCaptureStatus {
    case stopped
    case starting
    case running
    case error(String)
    case noPermission
}

/// Captures audio from the microphone and streams to the engine
class AudioCapture: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var retryCount = 0
    private let maxRetries = 3
    
    @Published var status: AudioCaptureStatus = .stopped
    
    /// Callback when audio chunk is captured (16kHz mono float32)
    var onAudioChunk: (([Float]) -> Void)?
    
    /// Callback for status changes
    var onStatusChange: ((AudioCaptureStatus) -> Void)?
    
    override init() {
        super.init()
        
        // Listen for audio device changes on macOS
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }
    
    @objc private func handleConfigurationChange(_ notification: Notification) {
        // Restart capture if configuration changed while running
        if isCapturing {
            print("[AudioCapture] Audio configuration changed, restarting...")
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.start()
            }
        }
    }
    
    /// Check if we have microphone permission
    func checkPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
    
    /// Request microphone permission
    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    /// Start capturing audio
    func start() {
        guard !isCapturing else { return }
        
        updateStatus(.starting)
        
        requestPermission { [weak self] granted in
            guard let self = self else { return }
            
            if granted {
                self.startCapture()
            } else {
                self.updateStatus(.noPermission)
            }
        }
    }
    
    private func startCapture() {
        // Clean up any existing engine
        if audioEngine != nil {
            stop()
        }
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            updateStatus(.error("Failed to create audio engine"))
            return
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Check if we have a valid input
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            updateStatus(.error("No audio input available"))
            scheduleRetry()
            return
        }
        
        // Target format: 16kHz mono float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            updateStatus(.error("Failed to create target audio format"))
            return
        }
        
        // Create converter for resampling
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            updateStatus(.error("Failed to create audio converter"))
            return
        }
        
        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }
        
        do {
            try audioEngine.start()
            isCapturing = true
            retryCount = 0
            updateStatus(.running)
            print("[AudioCapture] Started (input: \(Int(inputFormat.sampleRate))Hz → 16kHz)")
        } catch {
            updateStatus(.error("Failed to start: \(error.localizedDescription)"))
            scheduleRetry()
        }
    }
    
    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Calculate expected output frames based on sample rate conversion
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let expectedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: expectedFrames + 512
        ) else { return }
        
        var error: NSError?
        var hasData = true
        
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error {
            print("[AudioCapture] Conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        
        // Extract float samples
        guard let floatData = outputBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }
        
        // Send in 512-sample chunks (matching Python's blocksize, ~32ms at 16kHz)
        let chunkSize = 512
        var offset = 0
        var chunksSent = 0
        while offset + chunkSize <= frameCount {
            var chunk = [Float](repeating: 0, count: chunkSize)
            for i in 0..<chunkSize {
                chunk[i] = floatData[offset + i]
            }
            onAudioChunk?(chunk)
            offset += chunkSize
            chunksSent += 1
        }
        
    }
    
    private func scheduleRetry() {
        guard retryCount < maxRetries else {
            updateStatus(.error("Failed after \(maxRetries) retries"))
            return
        }
        
        retryCount += 1
        print("[AudioCapture] Retry \(retryCount)/\(maxRetries) in 2s...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.startCapture()
        }
    }
    
    private func updateStatus(_ newStatus: AudioCaptureStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
            self?.onStatusChange?(newStatus)
        }
    }
    
    /// Stop capturing audio
    func stop() {
        guard isCapturing || audioEngine != nil else { return }
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isCapturing = false
        updateStatus(.stopped)
        print("[AudioCapture] Stopped")
    }
}
