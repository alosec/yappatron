import Foundation

/// Coordinates continuous text refinement during streaming
@MainActor
class ContinuousRefinementManager {

    private let punctuationModel: PunctuationModel
    private let diffGenerator: DiffGenerator
    private let editApplier: EditApplier
    private let textTracker: TextStateTracker
    private let config: RefinementConfig

    // Throttling
    private var lastRefinementTime: Date?
    private var pendingRefinementTask: Task<Void, Never>?

    init(
        inputSimulator: InputSimulator,
        config: RefinementConfig = .default
    ) {
        self.punctuationModel = PunctuationModel(modelType: .rules)
        self.diffGenerator = DiffGenerator()
        self.editApplier = EditApplier(simulator: inputSimulator)
        self.textTracker = TextStateTracker()
        self.config = config
    }

    /// Called when partial transcription updates
    func onPartialUpdate(_ newText: String) {
        guard config.isEnabled else { return }

        textTracker.updateText(newText)

        // Cancel any pending refinement
        pendingRefinementTask?.cancel()

        // Throttle refinement
        if let lastTime = lastRefinementTime,
           Date().timeIntervalSince(lastTime) < config.throttleInterval {
            return
        }

        // Schedule refinement
        pendingRefinementTask = Task { [weak self] in
            await self?.performRefinement(originalText: newText)
        }
    }

    /// Perform refinement asynchronously
    private func performRefinement(originalText: String) async {
        lastRefinementTime = Date()

        // Get refined version from punctuation model
        let refinedText = await punctuationModel.refine(originalText)

        // Check if anything changed
        guard refinedText != originalText else { return }

        log("[ContinuousRefinement] Refining '\(originalText)' → '\(refinedText)'")

        // Generate edit commands
        let commands = await diffGenerator.generateCommands(
            from: originalText,
            to: refinedText,
            currentCursorAtEnd: textTracker.cursorAtEnd
        )

        // Apply edits
        let version = textTracker.getCurrentVersion()
        await editApplier.apply(commands, version: version)

        // Update tracked text
        textTracker.updateText(refinedText)
    }

    /// Reset for new utterance
    func reset() {
        pendingRefinementTask?.cancel()
        textTracker.reset()
        editApplier.clearQueue()
        lastRefinementTime = nil
    }
}
