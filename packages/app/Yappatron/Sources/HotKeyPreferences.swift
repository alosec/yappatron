import AppKit
import Foundation
import HotKey

extension Notification.Name {
    static let pushToTalkHotKeyDidChange = Notification.Name("pushToTalkHotKeyDidChange")
}

enum HotKeyPreferences {
    private static let pushToTalkKey = "pushToTalkHotKey"

    static var pushToTalkCombo: KeyCombo {
        get {
            guard let dictionary = UserDefaults.standard.dictionary(forKey: pushToTalkKey),
                  let combo = KeyCombo(dictionary: dictionary) else {
                return defaultPushToTalkCombo
            }

            return combo
        }
        set {
            UserDefaults.standard.set(newValue.dictionary, forKey: pushToTalkKey)
            NotificationCenter.default.post(name: .pushToTalkHotKeyDidChange, object: nil)
        }
    }

    static var defaultPushToTalkCombo: KeyCombo {
        KeyCombo(key: .rightOption)
    }

    static func displayString(for combo: KeyCombo) -> String {
        if combo.modifiers.isEmpty, let key = combo.key {
            switch key {
            case .option: return "Left ⌥"
            case .rightOption: return "Right ⌥"
            case .control: return "Left ⌃"
            case .rightControl: return "Right ⌃"
            case .shift: return "Left ⇧"
            case .rightShift: return "Right ⇧"
            case .command: return "Left ⌘"
            case .rightCommand: return "Right ⌘"
            default: break
            }
        }

        return combo.description.isEmpty ? "Unassigned" : combo.description
    }

    static func validationMessage(for combo: KeyCombo) -> String? {
        guard let key = combo.key else {
            return "That key cannot be used as a global shortcut."
        }

        if combo.modifiers.isEmpty && !allowsBareKey(key) {
            return "Use at least one modifier, or choose F13-F20."
        }

        for reserved in reservedAppShortcuts where reserved.combo == combo {
            return "Conflicts with \(reserved.name)."
        }

        if KeyCombo.standardKeyCombos().contains(combo) {
            return "Conflicts with a standard macOS shortcut."
        }

        if KeyCombo.systemKeyCombos().contains(combo) {
            return "Conflicts with an enabled system shortcut."
        }

        return nil
    }

    static func isModifierOnly(_ combo: KeyCombo) -> Bool {
        guard combo.modifiers.isEmpty, let key = combo.key else { return false }
        return isModifierKey(key)
    }

    static func modifierPressedState(for event: NSEvent, combo: KeyCombo) -> Bool? {
        guard isModifierOnly(combo), UInt32(event.keyCode) == combo.carbonKeyCode, let key = combo.key else {
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch key {
        case .option, .rightOption:
            return flags.contains(.option)
        case .control, .rightControl:
            return flags.contains(.control)
        case .shift, .rightShift:
            return flags.contains(.shift)
        case .command, .rightCommand:
            return flags.contains(.command)
        default:
            return nil
        }
    }

    private static var reservedAppShortcuts: [(name: String, combo: KeyCombo)] {
        [
            ("Toggle Pause", KeyCombo(key: .escape, modifiers: [.command])),
            ("Toggle Indicator", KeyCombo(key: .space, modifiers: [.option]))
        ]
    }

    private static func allowsBareKey(_ key: Key) -> Bool {
        if isModifierKey(key) {
            return true
        }

        switch key {
        case .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return true
        default:
            return false
        }
    }

    private static func isModifierKey(_ key: Key) -> Bool {
        switch key {
        case .option, .rightOption, .control, .rightControl, .shift, .rightShift, .command, .rightCommand:
            return true
        default:
            return false
        }
    }
}
