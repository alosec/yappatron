import Foundation
import AppKit
import Carbon.HIToolbox

/// Simulates keyboard input and detects focused text fields
class InputSimulator {
    
    /// Check if we have accessibility permissions (does NOT prompt)
    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Request accessibility permission (prompts user once)
    /// Returns true if already granted, false if prompt was shown
    static func requestAccessibilityPermissionIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        
        // Check if we've already prompted this session
        let hasPromptedKey = "hasPromptedForAccessibility"
        if UserDefaults.standard.bool(forKey: hasPromptedKey) {
            return false
        }
        
        // Prompt the user
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let result = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        // Remember that we prompted
        UserDefaults.standard.set(true, forKey: hasPromptedKey)
        
        return result
    }
    
    /// Type a single character
    func typeChar(_ char: String) {
        guard let char = char.first else { return }
        
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Create key down and up events
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        
        // Set the Unicode character
        var unicodeChar = UniChar(char.utf16.first ?? 0)
        keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
        keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
        
        // Post events
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    /// Type a string of characters
    func typeString(_ string: String, delay: TimeInterval = 0.01) {
        for char in string {
            typeChar(String(char))
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }
    
    /// Type text immediately (alias for typeString with no delay)
    func typeText(_ text: String) {
        typeString(text, delay: 0.005)
    }
    
    /// Delete a character (backspace)
    func deleteChar() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Backspace key code is 51
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    /// Delete multiple characters
    func deleteChars(_ count: Int, delay: TimeInterval = 0.005) {
        for _ in 0..<count {
            deleteChar()
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }
    
    /// Check if a text input is currently focused
    static func isTextInputFocused() -> Bool {
        // Get the system-wide accessibility element
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
        
        // Get the role of the focused element
        var role: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXRoleAttribute as CFString,
            &role
        )
        
        guard roleResult == .success, let roleString = role as? String else {
            return false
        }
        
        // Check if it's a text input role
        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField"  // kAXSearchFieldRole not available in all SDKs
        ]
        
        return textRoles.contains(roleString)
    }
    
    /// Get the currently focused application name
    static func getFocusedAppName() -> String? {
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }
    
    /// Get the bundle identifier of the focused application
    static func getFocusedAppBundleId() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

// Key codes from Carbon
private let kVK_Delete: Int = 0x33
