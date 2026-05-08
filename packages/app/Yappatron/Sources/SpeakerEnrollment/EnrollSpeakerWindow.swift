import AppKit
import Foundation
import SwiftUI

/// Floating window that records 10s of audio, runs embedding extraction, and
/// upserts the result into SpeakerRegistry under the given name. The caller
/// is expected to pause the active TranscriptionEngine before invoking.
@MainActor
final class EnrollSpeakerCoordinator {

    private var window: NSWindow?

    /// Movie/TV quotes around 10 seconds of natural reading length. Picked at
    /// random for the enrollment prompt so the user has something to read
    /// instead of fumbling for filler.
    private static let enrollmentQuotes: [String] = [
        "Frankly, my dear, I don't give a damn. After all, tomorrow is another day.",
        "I'm gonna make him an offer he can't refuse. We'll meet at the restaurant on Tuesday.",
        "May the Force be with you, always. The Force will be with you, even when you cannot see it.",
        "Houston, we have a problem. The main bus B undervolt is reading off the charts.",
        "You can't handle the truth! Son, we live in a world that has walls.",
        "Life is like a box of chocolates. You never know what you're gonna get on any given day.",
        "Here's looking at you, kid. We'll always have Paris, no matter where life takes us.",
        "I'll be back. And when I return, the future will be a very different place.",
        "Show me the money! Help me help you, and we'll do great things together.",
        "To infinity and beyond! There's a snake in my boot, and I think we should probably do something about that.",
        "Why so serious? Let's put a smile on that face. The world deserves a little chaos now and then.",
        "I see dead people. They walk around like regular people, they don't see each other, they only see what they want to see.",
        "Just keep swimming, just keep swimming. What do we do? We swim, swim, swim.",
        "There's no place like home. There's no place like home, if I ever go looking for my heart's desire."
    ]

    func enroll(suggestedName: String, embedder: SpeakerEmbedder, onDone: @escaping (Result<EnrolledSpeaker, Error>) -> Void) {
        let quote = Self.enrollmentQuotes.randomElement() ?? ""

        // Prompt for a name first.
        let alert = NSAlert()
        alert.messageText = "Enroll a speaker"
        alert.informativeText = """
        Speak naturally for 10 seconds after pressing Start. We'll capture your voiceprint locally.

        Stuck for what to say? Try reading this:

        \(quote)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = suggestedName
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        showRecordingWindow(name: name, quote: quote)

        Task {
            do {
                try await embedder.loadIfNeeded()
                let recorder = EnrollmentRecorder()
                let samples = try await recorder.record(for: EnrollmentRecorder.defaultDuration)
                guard let embedding = await embedder.embedding(for: samples) else {
                    self.closeRecordingWindow()
                    onDone(.failure(NSError(domain: "Enrollment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Embedding extraction failed"])))
                    return
                }
                let speaker = EnrolledSpeaker(
                    id: UUID().uuidString,
                    name: name,
                    embedding: embedding,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try SpeakerRegistry.upsert(speaker)
                self.closeRecordingWindow()
                onDone(.success(speaker))
            } catch {
                self.closeRecordingWindow()
                onDone(.failure(error))
            }
        }
    }

    private func showRecordingWindow(name: String, quote: String) {
        let view = RecordingView(name: name, quote: quote, totalDuration: EnrollmentRecorder.defaultDuration)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "Enrolling \(name)…"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 420, height: 180))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func closeRecordingWindow() {
        window?.close()
        window = nil
    }
}

private struct RecordingView: View {
    let name: String
    let quote: String
    let totalDuration: TimeInterval
    @State private var progress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording \(name)")
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            if !quote.isEmpty {
                Text("Read this aloud:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(quote)
                    .font(.body)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Speak naturally for \(Int(totalDuration)) seconds…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            Task {
                let steps = 100
                for i in 0...steps {
                    try? await Task.sleep(nanoseconds: UInt64(totalDuration * 1_000_000_000) / UInt64(steps))
                    await MainActor.run { progress = Double(i) / Double(steps) }
                }
            }
        }
    }
}
