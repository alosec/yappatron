import AVFoundation
import Foundation

/// Microphone-only capture using AVAudioEngine. Behavioral parity with
/// Yappatron's original audio path. Output is always 16kHz mono Float32.
final class MicAudioSource: AudioCaptureSource, @unchecked Sendable {

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var didLogTapFormat = false

    private(set) var isRunning: Bool = false
    private(set) var acousticEchoCancellationEnabled: Bool = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        if isRunning { return }
        self.onBuffer = onBuffer

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Voice Processing I/O removes audio currently playing from the Mac's
        // output device from the microphone signal. Unlike a hard capture gate,
        // it preserves the user's voice so they can interrupt local TTS.
        do {
            try input.setVoiceProcessingEnabled(true)
            acousticEchoCancellationEnabled = input.isVoiceProcessingEnabled
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            }
            log("MicAudioSource: acoustic echo cancellation enabled with minimum output ducking")
        } catch {
            acousticEchoCancellationEnabled = false
            log("MicAudioSource: acoustic echo cancellation unavailable; using raw mic (\(error.localizedDescription))")
        }

        let inputFormat = input.inputFormat(forBus: 0)
        let outputFormat = input.outputFormat(forBus: 0)
        log("MicAudioSource: input format \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch")
        log("MicAudioSource: output format \(Int(outputFormat.sampleRate))Hz, \(outputFormat.channelCount)ch")
        let captureFormat = inputFormat

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "MicAudioSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build 16k mono format"])
        }

        guard let monoCaptureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: captureFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: monoCaptureFormat, to: processingFormat) else {
            throw NSError(domain: "MicAudioSource", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create microphone format converter"])
        }

        // Let the node supply its real post-voice-processing format. Passing a
        // fixed tap format can produce empty buffers after Voice Processing I/O
        // changes the hardware format. Keep one converter alive across buffers
        // so its resampler does not discard priming frames on every callback.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if !self.didLogTapFormat {
                self.didLogTapFormat = true
                log("MicAudioSource: tap format \(Int(buffer.format.sampleRate))Hz, \(buffer.format.channelCount)ch, \(buffer.frameLength) frames")
            }
            if let monoBuffer = MicAudioSource.firstChannel(of: buffer, format: monoCaptureFormat),
               let converted = MicAudioSource.convert(monoBuffer, using: converter, to: processingFormat) {
                self.onBuffer?(converted)
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.inputNode = input
        self.isRunning = true
    }

    func stop() {
        if !isRunning { return }
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
        onBuffer = nil
        didLogTapFormat = false
        isRunning = false
        acousticEchoCancellationEnabled = false
    }

    static func firstChannel(of buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else {
            return nil
        }
        mono.frameLength = buffer.frameLength
        memcpy(destination, source, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        return mono
    }

    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return nil }
        var error: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return outputBuffer
    }
}
