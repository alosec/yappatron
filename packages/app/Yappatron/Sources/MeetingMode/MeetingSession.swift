import AppKit
import Foundation

/// Owns the lifetime of a meeting-mode transcription session:
/// - Swaps the active gate's decision to a label-everyone policy
/// - Routes transcribed text into a transcript window instead of keyboard
/// - Restores the previous decision (and dictation routing) when stopped
@MainActor
final class MeetingSession {

    let store: MeetingTranscriptStore
    private let windowController: MeetingTranscriptWindowController
    private weak var engine: TranscriptionEngine?
    private var pendingSpeakerName: String = "Unknown"

    init(engine: TranscriptionEngine) {
        self.engine = engine
        let store = MeetingTranscriptStore()
        self.store = store
        self.windowController = MeetingTranscriptWindowController(store: store) {
            // Stop button inside the window calls back to the app delegate.
            NotificationCenter.default.post(name: .stopMeetingMode, object: nil)
        }
    }

    /// Begin meeting mode. Hooks the engine's speaker label and final
    /// transcription callbacks, swaps the gate decision to label-everyone,
    /// and shows the transcript window.
    func start() {
        guard let engine else { return }

        // Build a label-everyone decision from the current registry.
        let lookup = engine.currentRegistryLookup()
        let labelDecision = RegistryLabelDecision(lookup: lookup)
        engine.swapGateDecision(labelDecision)

        // Track the active speaker label so when the next final lands we
        // know who said it.
        engine.onSpeakerLabel = { [weak self] name in
            self?.pendingSpeakerName = name
        }

        // Capture finals into the transcript instead of typing them.
        engine.onTranscription = { [weak self] text in
            guard let self else { return }
            let speaker = self.pendingSpeakerName
            self.store.append(speakerName: speaker, text: text)
        }

        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Stop the meeting and restore dictation routing. The caller is
    /// responsible for re-installing the previous engine callbacks because
    /// the engine doesn't keep a snapshot of "previous handlers" itself.
    func stop() {
        windowController.close()
        // Caller (AppDelegate) restores dictation callbacks + swaps the
        // decision back to the configured isolation policy.
    }

    var fileLocation: URL { store.fileLocation }
}

extension Notification.Name {
    static let stopMeetingMode = Notification.Name("Yappatron.stopMeetingMode")
}
