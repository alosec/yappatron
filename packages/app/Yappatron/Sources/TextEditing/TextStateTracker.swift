import Foundation

/// Tracks the current state of typed text
@MainActor
class TextStateTracker {

    private(set) var currentText: String = ""
    private(set) var version: Int = 0
    private(set) var cursorAtEnd: Bool = true

    /// Update text state
    func updateText(_ newText: String) {
        currentText = newText
        version += 1
    }

    /// Get current version
    func getCurrentVersion() -> Int {
        return version
    }

    /// Reset state (new utterance)
    func reset() {
        currentText = ""
        version += 1
        cursorAtEnd = true
    }

    /// Mark cursor position
    func setCursorAtEnd(_ atEnd: Bool) {
        cursorAtEnd = atEnd
    }
}
