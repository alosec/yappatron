import Foundation
import AppKit
import Carbon.HIToolbox

/// Simulates keyboard input with support for backspace corrections
class InputSimulator {

    private struct FocusedElementContext {
        let lookupResult: AXError
        let element: AXUIElement?
        let window: AXUIElement?
        let role: String?
        let subrole: String?

        var isStandardTextInput: Bool {
            guard let role else { return false }
            return standardTextInputRoles.contains(role)
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = pasteboard.pasteboardItems?.map { item in
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                return dataByType
            } ?? []
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()

            let pasteboardItems = items.map { dataByType in
                let item = NSPasteboardItem()
                for (type, data) in dataByType {
                    item.setData(data, forType: type)
                }
                return item
            }

            if !pasteboardItems.isEmpty {
                pasteboard.writeObjects(pasteboardItems)
            }
        }
    }

    final class InputFocusTarget {
        struct RestoreToken {
            private let previousApp: NSRunningApplication?
            private let lockedPID: pid_t

            init(previousApp: NSRunningApplication?, lockedPID: pid_t) {
                self.previousApp = previousApp
                self.lockedPID = lockedPID
            }

            func restore() {
                guard let previousApp,
                      !previousApp.isTerminated,
                      previousApp.processIdentifier != lockedPID else {
                    return
                }

                previousApp.activate(options: [])
            }
        }

        let element: AXUIElement
        let window: AXUIElement?
        let pid: pid_t
        let bundleID: String?
        let appName: String
        let windowTitle: String?
        let role: String?
        let subrole: String?

        var isCurrentProcess: Bool {
            pid == ProcessInfo.processInfo.processIdentifier
        }

        var displayName: String {
            if let windowTitle, !windowTitle.isEmpty {
                return "\(appName) — \(windowTitle)"
            }

            return appName
        }

        init(
            element: AXUIElement,
            window: AXUIElement?,
            pid: pid_t,
            bundleID: String?,
            appName: String,
            windowTitle: String?,
            role: String?,
            subrole: String?
        ) {
            self.element = element
            self.window = window
            self.pid = pid
            self.bundleID = bundleID
            self.appName = appName
            self.windowTitle = windowTitle
            self.role = role
            self.subrole = subrole
        }

        func focusForTyping() -> RestoreToken? {
            guard let app = runningApplication(), elementIsStillValid() else {
                return nil
            }

            let previousApp = NSWorkspace.shared.frontmostApplication
            app.activate(options: [])

            if let window {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, element)
            let focusResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

            Thread.sleep(forTimeInterval: 0.04)

            guard focusResult == .success || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return nil
            }

            return RestoreToken(previousApp: previousApp, lockedPID: pid)
        }

        func outlineFrame() -> NSRect? {
            let outlineElement = window ?? element
            guard let frame = InputSimulator.accessibilityFrame(for: outlineElement) else {
                return nil
            }

            return InputSimulator.cocoaFrame(fromAccessibilityFrame: frame).insetBy(dx: -5, dy: -5)
        }

        private func runningApplication() -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                return nil
            }

            if let bundleID, app.bundleIdentifier != bundleID {
                return nil
            }

            return app
        }

        private func elementIsStillValid() -> Bool {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        }
    }
    
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
        keyDown?.flags = []
        keyUp?.flags = []
        
        var unicodeChar = UniChar(char.utf16.first ?? 0)
        keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
        keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    /// Type a string character by character
    func typeString(_ string: String) {
        if string.contains(where: { $0 == "\n" || $0 == "\r" }) || Self.shouldPasteTextInsteadOfTyping() {
            pasteString(string)
            return
        }

        for char in string {
            typeChar(char)
            Thread.sleep(forTimeInterval: 0.002) // Small delay for reliability
        }
    }

    /// Paste a string while preserving the user's existing pasteboard contents.
    func pasteString(_ string: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)

        pressKey(0x09, modifiers: .maskCommand) // Cmd+V
        Thread.sleep(forTimeInterval: 0.15)

        snapshot.restore(to: pasteboard)
    }
    
    /// Delete a character (backspace)
    func deleteChar() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x33), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x33), keyDown: false)
        keyDown?.flags = []
        keyUp?.flags = []
        
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
        keyDown?.flags = []
        keyUp?.flags = []
        
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

    private static let standardTextInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private static let pasteFallbackBundleIDs: Set<String> = [
        // Code editors and terminals often expose canvas/web surfaces rather than AX text roles.
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",

        // Electron/web chat apps can report the focused element as HTML content while
        // the actual composer is an editable descendant.
        "com.tinyspeck.slackmacgap",
        "com.openai.codex",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "org.whispersystems.signal-desktop"
    ]
    
    static func isTextInputFocused() -> Bool {
        let context = focusedElementContext()
        if context.isStandardTextInput {
            return true
        }

        return frontmostAppUsesPasteFallback()
    }

    static func shouldPasteTextInsteadOfTyping() -> Bool {
        guard frontmostAppUsesPasteFallback() else {
            return false
        }

        return !focusedElementContext().isStandardTextInput
    }

    static func getFocusedAppName() -> String? {
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    static func captureFocusedTextInputTarget() -> InputFocusTarget? {
        let context = focusedElementContext()
        guard let element = context.element,
              context.isStandardTextInput || frontmostAppUsesPasteFallback(),
              let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let windowTitle = context.window.flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) }

        return InputFocusTarget(
            element: element,
            window: context.window,
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "Unknown App",
            windowTitle: windowTitle,
            role: context.role,
            subrole: context.subrole
        )
    }

    static func logTextInputFocusRejection() {
        let context = focusedElementContext()
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "unknown"
        let bundleID = app?.bundleIdentifier ?? "unknown"
        let lookupResult = String(describing: context.lookupResult)
        let role = context.role ?? "nil"
        let subrole = context.subrole ?? "nil"

        NSLog("[Yappatron] No text input focused: app=\(appName), bundleID=\(bundleID), focusedResult=\(lookupResult), role=\(role), subrole=\(subrole)")
    }

    private static func isStandardTextInputFocused() -> Bool {
        return focusedElementContext().isStandardTextInput
    }

    private static func focusedElementContext() -> FocusedElementContext {
        let systemWide = AXUIElementCreateSystemWide()
        
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        
        guard result == .success, let element = focusedElement else {
            return FocusedElementContext(lookupResult: result, element: nil, window: nil, role: nil, subrole: nil)
        }

        let axElement = element as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute as CFString, from: axElement)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: axElement)
        let window = elementAttribute(kAXWindowAttribute as CFString, from: axElement)

        return FocusedElementContext(lookupResult: result, element: axElement, window: window, role: role, subrole: subrole)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as? String
    }

    private static func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func accessibilityFrame(for element: AXUIElement) -> CGRect? {
        guard let position = cgPointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = cgSizeAttribute(kAXSizeAttribute as CFString, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func cgPointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private static func cgSizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private static func cocoaFrame(fromAccessibilityFrame frame: CGRect) -> NSRect {
        let screens = NSScreen.screens
        let maxY = screens.map { $0.frame.maxY }.max() ?? (NSScreen.main?.frame.maxY ?? frame.maxY)
        let converted = CGRect(
            x: frame.minX,
            y: maxY - frame.minY - frame.height,
            width: frame.width,
            height: frame.height
        )

        if intersectsAnyScreen(converted, screens: screens) {
            return converted
        }

        return frame
    }

    private static func intersectsAnyScreen(_ frame: CGRect, screens: [NSScreen]) -> Bool {
        screens.contains { screen in
            screen.frame.intersects(frame)
        }
    }

    private static func frontmostAppUsesPasteFallback() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return false
        }

        return pasteFallbackBundleIDs.contains(bundleID)
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

        keyDown?.flags = modifiers
        keyUp?.flags = modifiers

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
