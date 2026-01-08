import Foundation

/// Tracks typed text for undo functionality
class TextUndoManager: ObservableObject {
    static let shared = TextUndoManager()
    
    /// Text that has been typed (for undo)
    @Published private(set) var typedText: String = ""
    
    /// Maximum characters to track
    let maxLength = 2000
    
    private let inputSimulator = InputSimulator()
    
    private init() {}
    
    /// Record that text was typed
    func recordTyped(_ text: String) {
        typedText += text
        
        // Trim if too long
        if typedText.count > maxLength {
            typedText = String(typedText.suffix(maxLength))
        }
    }
    
    /// Undo the last word
    /// Returns the word that was undone
    @discardableResult
    func undoWord() -> String {
        guard !typedText.isEmpty else { return "" }
        
        var undone = ""
        
        // Remove trailing spaces
        while typedText.last == " " {
            let char = typedText.removeLast()
            undone = String(char) + undone
            inputSimulator.deleteChar()
        }
        
        // Remove word characters
        while !typedText.isEmpty && typedText.last != " " {
            let char = typedText.removeLast()
            undone = String(char) + undone
            inputSimulator.deleteChar()
        }
        
        return undone
    }
    
    /// Undo all typed text
    /// Returns the text that was undone
    @discardableResult
    func undoAll() -> String {
        guard !typedText.isEmpty else { return "" }
        
        let undone = typedText
        
        // Delete all characters
        for _ in typedText {
            inputSimulator.deleteChar()
        }
        
        typedText = ""
        return undone
    }
    
    /// Clear the undo buffer without deleting
    func clear() {
        typedText = ""
    }
}
