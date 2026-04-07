import AppKit
import SwiftUI

/// Modal flow for deliberately enrolling a new speaker.
/// Two-step: name → record → save.
@MainActor
final class AddSpeakerFlow {

    private let extractor: VoiceEmbeddingExtractor
    private let onSaved: (RegisteredSpeaker) -> Void

    static let enrollmentScript = """
    The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. \
    How razorback jumping frogs can level six piqued gymnasts. The five boxing wizards jump \
    quickly. Sphinx of black quartz, judge my vow. We promptly judged antique ivory buckles \
    of the next prize.
    """

    init(extractor: VoiceEmbeddingExtractor, onSaved: @escaping (RegisteredSpeaker) -> Void) {
        self.extractor = extractor
        self.onSaved = onSaved
    }

    /// Run the full enrollment dialog. Returns immediately; the actual capture
    /// happens asynchronously while a recording modal is shown.
    func run() {
        // Step 1: name + intro
        let intro = NSAlert()
        intro.messageText = "Add Speaker"
        intro.informativeText = """
        Enter a name for this speaker, then click Start. They will read the paragraph below in their normal speaking voice for \(Int(SpeakerEnrollmentManager.enrollmentDurationSeconds)) seconds.

        \(Self.enrollmentScript)
        """
        intro.alertStyle = .informational
        intro.addButton(withTitle: "Start")
        intro.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = "Speaker name (e.g. Alex, Bob)"
        intro.accessoryView = nameField
        intro.window.initialFirstResponder = nameField

        let response = intro.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let oops = NSAlert()
            oops.messageText = "Name Required"
            oops.informativeText = "Please enter a name for the speaker."
            oops.alertStyle = .warning
            oops.addButton(withTitle: "OK")
            oops.runModal()
            return
        }

        // Step 2: capture
        let recording = NSAlert()
        recording.messageText = "Recording \(name)…"
        recording.informativeText = "Reading the paragraph aloud. This window will close automatically when recording finishes."
        recording.alertStyle = .informational

        let manager = SpeakerEnrollmentManager(extractor: extractor)
        let onSaved = self.onSaved

        Task { @MainActor in
            do {
                let speaker = try await manager.enroll(name: name)
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                let success = NSAlert()
                success.messageText = "Saved ✓"
                success.informativeText = "\(name) has been added to your speaker registry. Restart Yappatron for the change to take effect."
                success.alertStyle = .informational
                success.addButton(withTitle: "OK")
                success.runModal()
                onSaved(speaker)
            } catch {
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                let failure = NSAlert()
                failure.messageText = "Enrollment Failed"
                failure.informativeText = "Could not enroll voice: \(error.localizedDescription)"
                failure.alertStyle = .warning
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }

        NSApp.runModal(for: recording.window)
    }
}
