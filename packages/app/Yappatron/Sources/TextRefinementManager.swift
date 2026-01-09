import Foundation

/// Coordinates dual-pass transcription refinement
/// Manages streaming → batch workflow and text replacement
@MainActor
class TextRefinementManager {

    private let batchProcessor: BatchProcessor
    private let inputSimulator: InputSimulator

    // Track refinement state
    private var isProcessing = false

    // Callback when refinement completes
    var onRefinementComplete: ((String) -> Void)?

    init(batchProcessor: BatchProcessor, inputSimulator: InputSimulator) {
        self.batchProcessor = batchProcessor
        self.inputSimulator = inputSimulator
    }

    /// Refine transcription using batch re-processing
    /// - Parameters:
    ///   - audioSamples: 16kHz mono audio samples from utterance
    ///   - streamedText: Original text from streaming ASR (unpunctuated)
    func refineTranscription(audioSamples: [Float], streamedText: String) {
        guard !isProcessing else {
            log("[TextRefinementManager] Already processing refinement, skipping")
            return
        }

        isProcessing = true

        Task { @MainActor in
            do {
                log("[TextRefinementManager] Starting refinement for: '\(streamedText)'")

                // Process audio through batch TDT model
                let refinedText = try await batchProcessor.transcribe(audioSamples)

                log("[TextRefinementManager] Refined: '\(refinedText)'")

                // Check if text actually changed
                let trimmedStreamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedRefined = refinedText.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmedStreamed.lowercased() == trimmedRefined.lowercased() {
                    // Only punctuation/capitalization changed
                    log("[TextRefinementManager] Words match, applying punctuation refinement")
                } else {
                    log("[TextRefinementManager] Text changed: accuracy improvement detected")
                }

                // Apply text update using diff-based replacement
                await MainActor.run {
                    inputSimulator.applyTextUpdate(from: streamedText, to: refinedText)
                    onRefinementComplete?(refinedText)
                }

                isProcessing = false

            } catch {
                log("[TextRefinementManager] Refinement failed: \(error.localizedDescription)")
                isProcessing = false
            }
        }
    }
}
