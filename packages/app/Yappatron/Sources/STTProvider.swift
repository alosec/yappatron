import Foundation
import AVFoundation

/// Protocol for speech-to-text providers (local or cloud)
protocol STTProvider: AnyObject {
    /// Initialize/connect the provider
    func start() async throws

    /// Process a 16kHz mono PCM audio buffer
    func processAudio(_ buffer: AVAudioPCMBuffer) async throws

    /// Flush and return the current utterance while keeping the provider ready for more audio
    func finishCurrentUtterance() async throws -> String?

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
    /// Called on is_final segments when the provider can attribute words to speakers.
    /// Runs are pre-grouped: consecutive same-speaker words are merged into one entry.
    /// Providers without diarization leave this nil.
    var onDiarizedFinal: (([(speakerId: Int, text: String)]) -> Void)? { get set }
}
