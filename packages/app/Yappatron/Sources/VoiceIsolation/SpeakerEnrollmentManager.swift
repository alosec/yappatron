import AVFoundation
import Foundation

/// Captures ~10 seconds of microphone audio and produces a stored voiceprint.
///
/// Owns its own AVAudioEngine; the caller is expected to pause the main TranscriptionEngine
/// before invoking enroll() so the two don't fight over the input device.
@MainActor
final class SpeakerEnrollmentManager {

    enum EnrollmentError: Error {
        case microphoneDenied
        case audioEngineFailed(String)
        case extractionFailed
    }

    /// Default enrollment audio duration. ~10s gives the diarizer enough material
    /// to produce a stable embedding while staying friendly to the user.
    nonisolated static let enrollmentDurationSeconds: Double = 10.0

    private let extractor: VoiceEmbeddingExtractor

    init(extractor: VoiceEmbeddingExtractor) {
        self.extractor = extractor
    }

    /// Capture mic audio for `duration` seconds, extract the speaker's embedding,
    /// and persist them to the registry as an enrolled (allowed) speaker.
    /// Throws on permission/IO/extraction failures.
    func enroll(
        name: String,
        duration: TimeInterval = enrollmentDurationSeconds
    ) async throws -> RegisteredSpeaker {

        let granted = await Self.requestMicrophonePermission()
        guard granted else { throw EnrollmentError.microphoneDenied }

        // Load the extractor up front so the user doesn't sit through model
        // downloads with a hot mic.
        try await extractor.loadIfNeeded()

        let samples = try await captureAudio(for: duration)

        guard let embedding = await extractor.extractDominantEmbedding(from: samples) else {
            throw EnrollmentError.extractionFailed
        }

        let speaker = RegisteredSpeaker(
            id: UUID().uuidString,
            name: name,
            embedding: embedding,
            allowed: true,
            source: .enrolled,
            createdAt: Date(),
            updatedAt: Date()
        )
        try SpeakerRegistry.upsert(speaker)
        log("SpeakerEnrollmentManager: enrolled '\(name)', \(embedding.count)-dim embedding")
        return speaker
    }

    // MARK: - Audio capture

    private func captureAudio(for duration: TimeInterval) async throws -> [Float] {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw EnrollmentError.audioEngineFailed("could not build 16k mono format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
            throw EnrollmentError.audioEngineFailed("could not create AVAudioConverter")
        }

        // Use a class-based collector so the tap closure (non-isolated) can append safely
        // via a serial queue without crossing actor boundaries.
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
            throw EnrollmentError.audioEngineFailed(error.localizedDescription)
        }

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        engine.stop()
        inputNode.removeTap(onBus: 0)

        return collector.snapshot()
    }

    private static func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

/// Thread-safe sample buffer used by the enrollment audio tap.
private final class SampleCollector: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ chunk: [Float]) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
