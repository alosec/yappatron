import Foundation
import AVFoundation

/// Protocol for speech-to-text providers (local or cloud)
protocol STTProvider: AnyObject {
    /// Initialize/connect the provider
    func start() async throws

    /// Process a 16kHz mono PCM audio buffer
    func processAudio(_ buffer: AVAudioPCMBuffer) async throws

    /// Signal end of audio stream and get any remaining text
    func finish() async throws -> String?

    /// Reset state for next utterance
    func reset() async

    /// Clean up resources
    func cleanup()

    /// Callbacks
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    /// Called when locked (is_final) text advances — parameter is the locked text length
    var onLockedTextAdvanced: ((Int) -> Void)? { get set }
    /// Called when the active speaker for the current verified window is identified
    /// (only fires from VoiceIsolationGate; raw providers leave this nil).
    var onSpeakerLabel: ((String) -> Void)? { get set }
}

