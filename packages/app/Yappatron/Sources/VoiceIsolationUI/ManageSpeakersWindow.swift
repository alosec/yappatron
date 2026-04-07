import AppKit
import SwiftUI

/// Live-editable list of registered speakers. Each row exposes a name field,
/// an allowed toggle, and a delete button. Mutations write back to the
/// SpeakerRegistry on disk immediately.
@MainActor
final class ManageSpeakersViewModel: ObservableObject {
    @Published var speakers: [RegisteredSpeaker] = []

    init() {
        reload()
    }

    func reload() {
        speakers = SpeakerRegistry.loadAll().sorted { $0.createdAt < $1.createdAt }
    }

    func setName(id: String, name: String) {
        try? SpeakerRegistry.setName(id: id, name: name)
        reload()
    }

    func setAllowed(id: String, allowed: Bool) {
        try? SpeakerRegistry.setAllowed(id: id, allowed: allowed)
        reload()
    }

    func delete(id: String) {
        try? SpeakerRegistry.remove(id: id)
        reload()
    }
}

struct ManageSpeakersView: View {
    @ObservedObject var viewModel: ManageSpeakersViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Registered Speakers")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.speakers.count) total")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(12)
            .background(.bar)

            Divider()

            if viewModel.speakers.isEmpty {
                VStack {
                    Spacer()
                    Text("No speakers registered yet.")
                        .foregroundStyle(.secondary)
                    Text("Use 'Add Speaker…' to enroll someone, or enable Capture mode to register unknown voices automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.speakers) { speaker in
                        SpeakerRow(speaker: speaker, viewModel: viewModel)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("Restart Yappatron after editing for changes to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

private struct SpeakerRow: View {
    let speaker: RegisteredSpeaker
    @ObservedObject var viewModel: ManageSpeakersViewModel

    @State private var nameField: String = ""
    @State private var didLoadInitial: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $nameField, onCommit: {
                    let trimmed = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != speaker.name {
                        viewModel.setName(id: speaker.id, name: trimmed)
                    }
                })
                .textFieldStyle(.roundedBorder)

                Text(badgeLabel(for: speaker))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Allowed", isOn: Binding(
                get: { speaker.allowed },
                set: { viewModel.setAllowed(id: speaker.id, allowed: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button(role: .destructive) {
                viewModel.delete(id: speaker.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .onAppear {
            if !didLoadInitial {
                nameField = speaker.name
                didLoadInitial = true
            }
        }
    }

    private func badgeLabel(for speaker: RegisteredSpeaker) -> String {
        let sourceLabel = speaker.source == .enrolled ? "enrolled" : "auto-captured"
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(sourceLabel) · \(formatter.string(from: speaker.createdAt))"
    }
}

@MainActor
final class ManageSpeakersWindowController: NSWindowController {
    convenience init() {
        let viewModel = ManageSpeakersViewModel()
        let view = ManageSpeakersView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Manage Speakers"
        window.setContentSize(NSSize(width: 520, height: 420))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
