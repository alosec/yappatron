import AVFoundation
import Foundation
import ScreenCaptureKit
import CoreMedia

/// System audio capture via ScreenCaptureKit. Captures everything the system is
/// playing (FaceTime, Zoom, browser, music) and emits it as 16kHz mono Float32
/// PCM buffers. Yappatron's window is excluded so it can't capture itself.
///
/// Requires Screen Recording permission (granted via macOS TCC).
@available(macOS 13.0, *)
final class SystemAudioSource: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private var stream: SCStream?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning: Bool = false

    /// 16kHz mono target format.
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Cached source format detected from the first incoming sample buffer; used
    /// to build the converter for downsampling/downmixing.
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        if isRunning { return }
        self.onBuffer = onBuffer

        // Discover shareable content; we don't actually filter to a specific
        // window — we want all system audio. SCContentFilter still requires a
        // display anchor.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        // Exclude Yappatron's own audio so we don't pick up our own UI sounds.
        let yappatronApps = content.applications.filter { app in
            app.bundleIdentifier.contains("yappatron") || app.bundleIdentifier == "com.yappatron.app"
        }

        let filter = SCContentFilter(display: display, excludingApplications: yappatronApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // We don't need video — but SCStreamConfiguration requires sane values.
        // Set the smallest possible video frame to minimize CPU.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps, ignored — we don't consume video output
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "yap.system-audio.handler"))
        try await stream.startCapture()

        self.stream = stream
        self.isRunning = true
        log("SystemAudioSource: started (excludes \(yappatronApps.count) Yappatron processes)")
    }

    func stop() {
        if !isRunning { return }
        let stream = self.stream
        self.stream = nil
        self.onBuffer = nil
        self.isRunning = false
        Task {
            try? await stream?.stopCapture()
        }
        log("SystemAudioSource: stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let pcm = makePCMBuffer(from: sampleBuffer) else { return }
        if let converted = downconvert(pcm) {
            onBuffer?(converted)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SystemAudioSource: stream stopped with error: \(error.localizedDescription)")
        self.stream = nil
        self.isRunning = false
    }

    // MARK: - Helpers

    /// Convert a CMSampleBuffer of audio into an AVAudioPCMBuffer in the source format.
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy raw bytes from CMSampleBuffer into the PCM buffer.
        let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer!,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        // ScreenCaptureKit emits non-interleaved Float32. Each channel has its
        // own contiguous block; in the source's audioBufferList, channels are
        // separate AudioBuffers.
        let audioBufferList = buffer.mutableAudioBufferList
        let channelCount = Int(format.channelCount)
        let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Float>.size
        let listPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)

        if format.isInterleaved {
            // Interleaved: copy the whole block into the single AudioBuffer.
            if listPtr.count > 0 {
                memcpy(listPtr[0].mData, dataPointer, totalLength)
            }
        } else {
            // Non-interleaved: ScreenCaptureKit packs all channels into one block,
            // channel-major. Copy each channel's stride into its own AudioBuffer.
            for channel in 0..<min(channelCount, listPtr.count) {
                let src = dataPointer.advanced(by: channel * bytesPerChannel)
                memcpy(listPtr[channel].mData, src, bytesPerChannel)
            }
        }

        if sourceFormat == nil {
            sourceFormat = format
            log("SystemAudioSource: source format = \(format.channelCount)ch, \(Int(format.sampleRate))Hz, interleaved=\(format.isInterleaved)")
        }

        return buffer
    }

    /// Downsample/downmix to 16kHz mono Float32 using AVAudioConverter.
    private func downconvert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || sourceFormat?.channelCount != buffer.format.channelCount {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCount) else {
            return nil
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }
}
