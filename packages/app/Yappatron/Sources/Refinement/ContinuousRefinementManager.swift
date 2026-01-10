import Foundation

/// Coordinates text refinement using LLM
/// Processes full utterances on natural boundaries (EOU)
@MainActor
class ContinuousRefinementManager {

    private let punctuationModel: PunctuationModel
    private let inputSimulator: InputSimulator
    private let config: RefinementConfig

    // Track current state
    private var currentStreamedText: String = ""
    private var lastRefinedText: String = ""

    // Throttling
    private var pendingRefinementTask: Task<Void, Never>?

    init(
        inputSimulator: InputSimulator,
        config: RefinementConfig = .default
    ) {
        self.punctuationModel = PunctuationModel()
        self.inputSimulator = inputSimulator
        self.config = config
    }

    /// Called when utterance completes (EOU detected)
    /// This is when we apply LLM refinement
    func refineCompleteUtterance(_ streamedText: String, completion: (() -> Void)? = nil) {
        log("[ContinuousRefinement] refineCompleteUtterance called with: '\(streamedText)'")

        guard config.isEnabled else {
            log("[ContinuousRefinement] Config disabled")
            completion?()
            return
        }
        guard !streamedText.isEmpty else {
            log("[ContinuousRefinement] Empty text")
            completion?()
            return
        }

        currentStreamedText = streamedText

        // Cancel any pending refinement
        pendingRefinementTask?.cancel()

        log("[ContinuousRefinement] Scheduling refinement task")

        // Schedule refinement
        pendingRefinementTask = Task { [weak self] in
            log("[ContinuousRefinement] Refinement task started")
            await self?.performRefinement()
            // Call completion on main thread after refinement
            await MainActor.run {
                log("[ContinuousRefinement] Calling completion callback")
                completion?()
            }
        }
    }

    /// Perform LLM-based refinement
    private func performRefinement() async {
        let originalText = currentStreamedText

        // Get refined version from LLM
        let refinedText = await punctuationModel.refine(originalText, context: lastRefinedText)

        // Check if anything changed
        guard refinedText != originalText else {
            log("[ContinuousRefinement] No changes needed for: '\(originalText)'")
            return
        }

        log("[ContinuousRefinement] Refining '\(originalText)' → '\(refinedText)'")

        // Simple replacement: delete old, type new
        // Use existing applyTextUpdate which does smart prefix-based diff
        inputSimulator.applyTextUpdate(from: originalText, to: refinedText)

        // Update context for next utterance
        lastRefinedText = refinedText
    }

    /// Reset for new session
    func reset() {
        pendingRefinementTask?.cancel()
        currentStreamedText = ""
        lastRefinedText = ""
    }
}
