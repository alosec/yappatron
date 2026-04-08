import AppKit
import SwiftUI

/// Modal flow for deliberately enrolling a new speaker.
/// Three-step: name prompt → recording window (non-blocking, with live progress) → result alert.
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

    /// Runs the full enrollment dialog. Returns immediately; the capture and
    /// result presentation happen asynchronously via a non-blocking NSWindow.
    func run() {
        // Step 1: name + intro (simple blocking alert; this one is fine as-is)
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

        // Step 2: show a proper (non-modal) recording window with live progress.
        let recordingController = RecordingWindowController(name: name)
        recordingController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Step 3: run the capture in the background and update the window as it progresses.
        let manager = SpeakerEnrollmentManager(extractor: extractor)
        let duration = SpeakerEnrollmentManager.enrollmentDurationSeconds
        let onSaved = self.onSaved

        Task { @MainActor in
            // Kick off a progress animator that drives the window's progress bar
            // independently of the actual capture, so the UI feels responsive.
            let progressTask = Task { @MainActor in
                let totalSteps = 100
                for step in 0...totalSteps {
                    if Task.isCancelled { return }
                    recordingController.setProgress(Double(step) / Double(totalSteps))
                    try? await Task.sleep(nanoseconds: UInt64((duration / Double(totalSteps)) * 1_000_000_000))
                }
            }

            do {
                let speaker = try await manager.enroll(name: name)
                progressTask.cancel()
                recordingController.setProgress(1.0)
                recordingController.close()

                let success = NSAlert()
                success.messageText = "Saved ✓"
                success.informativeText = "\(name) has been added to your speaker registry. Restart Yappatron for the change to take effect."
                success.alertStyle = .informational
                success.addButton(withTitle: "OK")
                success.runModal()
                onSaved(speaker)
            } catch {
                progressTask.cancel()
                recordingController.close()
                let failure = NSAlert()
                failure.messageText = "Enrollment Failed"
                failure.informativeText = "Could not enroll voice: \(error.localizedDescription)"
                failure.alertStyle = .warning
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }
    }
}

// MARK: - Recording window

/// Small SwiftUI view hosted in an NSWindow showing a live progress bar.
/// Non-modal — the enrollment Task drives it and closes it when finished.
private struct RecordingView: View {
    let name: String
    @ObservedObject var model: RecordingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording \(name)")
                    .font(.headline)
                Text("Read the paragraph aloud in your normal speaking voice. This window will close automatically when recording finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
        }
        .padding(20)
        .frame(width: 420)
    }
}

@MainActor
private final class RecordingViewModel: ObservableObject {
    @Published var progress: Double = 0
}

@MainActor
private final class RecordingWindowController: NSWindowController {
    private let viewModel = RecordingViewModel()

    init(name: String) {
        let view = RecordingView(name: name, model: viewModel)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Enroll Speaker"
        window.styleMask = [.titled]  // no close button — the flow is driven by the Task
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setProgress(_ value: Double) {
        viewModel.progress = value
    }
}
