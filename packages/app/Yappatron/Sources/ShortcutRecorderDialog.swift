import AppKit
import HotKey

@MainActor
enum ShortcutRecorderDialog {
    static func runModal(currentCombo: KeyCombo) -> KeyCombo? {
        let alert = NSAlert()
        alert.messageText = "Choose Push-to-Talk Shortcut"
        alert.informativeText = "Press the shortcut you want to hold while speaking. Modifier-only keys like Right Option are supported."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        var recordedCombo = currentCombo

        let shortcutLabel = NSTextField(labelWithString: HotKeyPreferences.displayString(for: currentCombo))
        shortcutLabel.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        shortcutLabel.alignment = .center

        let helpLabel = NSTextField(labelWithString: "Current shortcut")
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.alignment = .center

        let stack = NSStackView(views: [shortcutLabel, helpLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.setFrameSize(NSSize(width: 320, height: 72))
        alert.accessoryView = stack

        let saveButton = alert.buttons.first
        saveButton?.isEnabled = HotKeyPreferences.validationMessage(for: currentCombo) == nil

        func record(_ combo: KeyCombo) {
            recordedCombo = combo

            shortcutLabel.stringValue = HotKeyPreferences.displayString(for: combo)

            if let message = HotKeyPreferences.validationMessage(for: combo) {
                helpLabel.stringValue = message
                helpLabel.textColor = .systemRed
                saveButton?.isEnabled = false
            } else {
                helpLabel.stringValue = "Hold this shortcut to dictate in Push to Talk mode"
                helpLabel.textColor = .secondaryLabelColor
                saveButton?.isEnabled = true
            }
        }

        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let combo = KeyCombo(carbonKeyCode: UInt32(event.keyCode), carbonModifiers: modifiers.carbonFlags)
                record(combo)
            case .flagsChanged:
                let combo = KeyCombo(carbonKeyCode: UInt32(event.keyCode), carbonModifiers: 0)
                if HotKeyPreferences.modifierPressedState(for: event, combo: combo) == true {
                    record(combo)
                }
            default:
                break
            }

            return nil
        }

        let response = alert.runModal()

        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }

        return response == .alertFirstButtonReturn ? recordedCombo : nil
    }
}
