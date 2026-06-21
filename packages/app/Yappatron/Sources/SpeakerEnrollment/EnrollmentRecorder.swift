import AVFoundation
import Foundation

/// Captures ~10 seconds of microphone audio at 16kHz mono Float32, owned by its
/// own AVAudioEngine. Caller is expected to pause TranscriptionEngine before
/// invoking `record(for:)` so the two don't fight over the input device.
@MainActor
final class EnrollmentRecorder {

    enum RecordingError: Error {
        case microphoneDenied
        case audioEngineFailed(String)
    }

    static let defaultDuration: TimeInterval = 10.0

    func record(for duration: TimeInterval = 10.0) async throws -> [Float] {
        let granted = await Self.requestMicrophonePermission()
        guard granted else { throw RecordingError.microphoneDenied }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.audioEngineFailed("could not build 16k mono format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
            throw RecordingError.audioEngineFailed("could not create AVAudioConverter")
        }

        let collector = SampleCollector()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = processingFormat.sampleRate / inputFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let out = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: outFrames) else {
                return
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil, let channelData = out.floatChannelData else { return }
            let frameLength = Int(out.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            collector.append(samples)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecordingError.audioEngineFailed(error.localizedDescription)
        }

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        engine.stop()
        inputNode.removeTap(onBus: 0)

        return collector.snapshot()
    }

    private static func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }
}

private final class SampleCollector: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()
    func append(_ chunk: [Float]) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
