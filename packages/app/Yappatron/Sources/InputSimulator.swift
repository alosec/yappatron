import Foundation
import AppKit
import Carbon.HIToolbox

/// Simulates keyboard input with support for backspace corrections
class InputSimulator {
    
    // MARK: - Accessibility Permission
    
    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermissionIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    // MARK: - Typing
    
    /// Type a single character
    func typeChar(_ char: Character) {
        let source = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        
        var unicodeChar = UniChar(char.utf16.first ?? 0)
        keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
        keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    /// Type a string character by character
    func typeString(_ string: String) {
        for char in string {
            typeChar(char)
            Thread.sleep(forTimeInterval: 0.002) // Small delay for reliability
        }
    }
    
    /// Delete a character (backspace)
    func deleteChar() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x33), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x33), keyDown: false)
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    /// Delete multiple characters
    func deleteChars(_ count: Int) {
        for _ in 0..<count {
            deleteChar()
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
    
    /// Press Enter/Return key
    func pressEnter() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x24), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x24), keyDown: false)
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    // MARK: - Smart Streaming
    
    /// Apply a text update with minimal keystrokes
    /// Compares old vs new text and uses backspace + type to correct
    func applyTextUpdate(from oldText: String, to newText: String) {
        // Find common prefix
        let commonPrefixLength = zip(oldText, newText).prefix(while: { $0 == $1 }).count
        
        // Calculate how many chars to delete and what to add
        let charsToDelete = oldText.count - commonPrefixLength
        let newSuffix = String(newText.dropFirst(commonPrefixLength))
        
        // Delete divergent chars
        if charsToDelete > 0 {
            deleteChars(charsToDelete)
        }
        
        // Type new suffix
        if !newSuffix.isEmpty {
            typeString(newSuffix)
        }
    }
    
    // MARK: - Context Detection
    
    static func isTextInputFocused() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        
        guard result == .success, let element = focusedElement else {
            return false
        }
        
        var role: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXRoleAttribute as CFString,
            &role
        )
        
        guard roleResult == .success, let roleString = role as? String else {
            return false
        }
        
        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField"
        ]
        
        return textRoles.contains(roleString)
    }
    
    static func getFocusedAppName() -> String? {
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }
}

// MARK: - Virtual Key Codes

extension InputSimulator {
    enum VirtualKey: CGKeyCode {
        case returnKey = 0x24
        case delete = 0x33          // Backspace
        case forwardDelete = 0x75   // Fn+Delete
        case leftArrow = 0x7B
        case rightArrow = 0x7C
        case downArrow = 0x7D
        case upArrow = 0x7E
        case home = 0x73
        case end = 0x77
        case pageUp = 0x74
        case pageDown = 0x79
    }
}

// MARK: - Navigation

extension InputSimulator {
    /// Navigate cursor to a specific position
    func navigate(to position: NavigateCommand.Position) throws {
        switch position {
        case .home:
            // Cmd+Left Arrow
            pressKey(.leftArrow, modifiers: .maskCommand)
        case .end:
            // Cmd+Right Arrow
            pressKey(.rightArrow, modifiers: .maskCommand)
        case .lineStart:
            // Ctrl+A (Emacs binding)
            pressKey(0x00, modifiers: .maskControl) // 'a'
        case .lineEnd:
            // Ctrl+E (Emacs binding)
            pressKey(0x0E, modifiers: .maskControl) // 'e'
        case .wordForward:
            // Option+Right Arrow
            pressKey(.rightArrow, modifiers: .maskAlternate)
        case .wordBackward:
            // Option+Left Arrow
            pressKey(.leftArrow, modifiers: .maskAlternate)
        case .characterForward(let count):
            for _ in 0..<count {
                pressKey(.rightArrow, modifiers: [])
                Thread.sleep(forTimeInterval: 0.002)
            }
        case .characterBackward(let count):
            for _ in 0..<count {
                pressKey(.leftArrow, modifiers: [])
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }
}

// MARK: - Selection

extension InputSimulator {
    /// Select text range
    func select(range: SelectCommand.Range) throws {
        switch range {
        case .characters(let count, let direction):
            let key: VirtualKey = direction == .forward ? .rightArrow : .leftArrow
            for _ in 0..<count {
                pressKey(key, modifiers: .maskShift)
                Thread.sleep(forTimeInterval: 0.002)
            }
        case .words(let count, let direction):
            let key: VirtualKey = direction == .forward ? .rightArrow : .leftArrow
            for _ in 0..<count {
                pressKey(key, modifiers: [.maskShift, .maskAlternate])
                Thread.sleep(forTimeInterval: 0.002)
            }
        case .toLineStart:
            pressKey(.leftArrow, modifiers: [.maskShift, .maskCommand])
        case .toLineEnd:
            pressKey(.rightArrow, modifiers: [.maskShift, .maskCommand])
        case .all:
            pressKey(0x00, modifiers: .maskCommand) // Cmd+A
        }
    }
}

// MARK: - Delete

extension InputSimulator {
    func delete(target: DeleteCommand.Target) throws {
        switch target {
        case .selection:
            // Just press delete - removes current selection
            pressKey(.delete, modifiers: [])
        case .backward(let count):
            deleteChars(count) // Use existing method
        case .forward(let count):
            for _ in 0..<count {
                pressKey(.forwardDelete, modifiers: [])
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }
}

// MARK: - Low-level Key Press Helper

extension InputSimulator {
    /// Press a key with modifiers
    func pressKey(_ key: VirtualKey, modifiers: CGEventFlags) {
        pressKey(key.rawValue, modifiers: modifiers)
    }

    func pressKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        if !modifiers.isEmpty {
            keyDown?.flags = modifiers
            keyUp?.flags = modifiers
        }

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
