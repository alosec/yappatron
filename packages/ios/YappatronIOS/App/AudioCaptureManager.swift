import AVFoundation
import Foundation

final class AudioCaptureManager {
    enum CaptureError: LocalizedError {
        case microphonePermissionDenied
        case noInputDevice
        case couldNotCreateFormat
        case couldNotCreateConverter

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission is required."
            case .noInputDevice:
                return "No microphone input is available."
            case .couldNotCreateFormat:
                return "Could not create the 16 kHz mono audio format."
            case .couldNotCreateConverter:
                return "Could not create the audio converter."
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(onChunk: @escaping (Data) -> Void) async throws {
        guard await requestPermission() else {
            throw CaptureError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .duckOthers]
        )
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.couldNotCreateFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.couldNotCreateConverter
        }

        self.converter = converter

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let convertedBuffer = self.convert(buffer, using: converter, to: outputFormat),
                  let data = Self.linear16Data(from: convertedBuffer) else {
                return
            }

            onChunk(data)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            return nil
        }

        return outputBuffer
    }

    private static func linear16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        let samples = channelData[0]
        var data = Data(count: frameLength * MemoryLayout<Int16>.size)

        data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<frameLength {
                let clampedSample = max(-1, min(1, samples[index]))
                int16Buffer[index] = Int16(clampedSample * Float(Int16.max))
            }
        }

        return data
    }
}
