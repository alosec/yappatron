import AppKit
import SwiftUI

/// Live transcript view for an active meeting session.
/// Lists `(speakerName: text)` lines as they come in, grouped visually but
/// not collapsed — every utterance is its own row so you can see turn-taking.
struct MeetingTranscriptView: View {

    @ObservedObject var store: MeetingTranscriptStore
    let onStop: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting in progress")
                        .font(.headline)
                    Text("Started \(Self.timeFormatter.string(from: store.sessionStartedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop Meeting", action: onStop)
                    .keyboardShortcut(.escape, modifiers: [.command])
            }
            .padding(12)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if store.entries.isEmpty {
                            Text("Waiting for speech…")
                                .foregroundStyle(.secondary)
                                .padding()
                        } else {
                            ForEach(store.entries) { entry in
                                entryRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.entries.count) { _, _ in
                    if let last = store.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func entryRow(_ entry: MeetingTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.speakerName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(entry.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// AppKit window wrapper so we can show the transcript independently of the
/// app's settings/menu UI.
@MainActor
final class MeetingTranscriptWindowController: NSWindowController {

    convenience init(store: MeetingTranscriptStore, onStop: @escaping () -> Void) {
        let view = MeetingTranscriptView(store: store, onStop: onStop)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Yappatron Meeting"
        window.setContentSize(NSSize(width: 520, height: 420))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
