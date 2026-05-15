import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DictationViewModel()
    @State private var settingsPresented = false

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundColor.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 26)
                    ListeningStateView(
                        phase: viewModel.listeningPhase,
                        audioLevel: viewModel.audioLevel
                    )
                    .frame(width: 250, height: 250)

                    VStack(spacing: 8) {
                        Text(viewModel.listeningPhase.title)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(primaryTextColor)

                        Text(viewModel.listeningPhase.detail)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(minHeight: 82)

                    transcriptHint
                        .padding(.top, 24)

                    Spacer(minLength: 28)

                    Button {
                        viewModel.toggleRecording()
                    } label: {
                        Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(primaryButtonTint)
                    .disabled(viewModel.status == .connecting || viewModel.status == .finishing)

                    destinationStrip
                        .padding(.top, 14)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $settingsPresented) {
                SettingsView(viewModel: viewModel)
            }
            .onAppear {
                viewModel.autoStartIfNeeded()
            }
            .onOpenURL { url in
                viewModel.handleIncomingURL(url)
            }
            .onChange(of: viewModel.autoStartListening) { _, _ in
                viewModel.autoStartIfNeeded()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text("Yappatron")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if viewModel.canShareTranscript {
                ShareLink(item: viewModel.transcript) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share transcript")
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private var transcriptHint: some View {
        let text = viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && viewModel.listeningPhase != .quiet && viewModel.listeningPhase != .off {
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 74)
                .padding(.horizontal, 12)
                .textSelection(.enabled)
        } else {
            Color.clear
                .frame(height: 74)
        }
    }

    private var destinationStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: destinationIcon)
            Text(destinationText)
                .lineLimit(1)
            Spacer()
            if viewModel.webhookPostsFailed > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var destinationText: String {
        if viewModel.streamToWebhook && viewModel.autoInsertOnKeyboardOpen {
            return "Webhook + Keyboard"
        }
        if viewModel.streamToWebhook {
            return "Webhook"
        }
        if viewModel.autoInsertOnKeyboardOpen {
            return "Keyboard"
        }
        return "Keyboard ready"
    }

    private var destinationIcon: String {
        viewModel.streamToWebhook ? "antenna.radiowaves.left.and.right" : "keyboard"
    }

    private var primaryButtonTitle: String {
        viewModel.isRecording ? "Stop" : "Start"
    }

    private var primaryButtonIcon: String {
        viewModel.isRecording ? "stop.fill" : "mic.fill"
    }

    private var primaryButtonTint: Color {
        viewModel.isRecording ? .red : .blue
    }

    private var backgroundColor: Color {
        switch viewModel.listeningPhase {
        case .attention:
            return Color(.systemBackground)
        default:
            return Color(.systemGroupedBackground)
        }
    }

    private var primaryTextColor: Color {
        switch viewModel.listeningPhase {
        case .attention:
            return .red
        default:
            return .primary
        }
    }
}

private struct ListeningStateView: View {
    let phase: DictationViewModel.ListeningPhase
    let audioLevel: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(min(1, max(0, audioLevel)))
            let pulse = CGFloat((sin(time * speed) + 1) / 2)

            ZStack {
                Circle()
                    .fill(baseColor.opacity(baseOpacity))
                    .frame(width: 184, height: 184)
                    .scaleEffect(1 + level * 0.08 + pulse * pulseScale)

                Circle()
                    .stroke(accentColor.opacity(ringOpacity), lineWidth: 3 + level * 7)
                    .frame(width: 212, height: 212)
                    .scaleEffect(1 + pulse * ringScale + level * 0.05)

                WaveBars(level: level, color: accentColor)
                    .frame(width: 136, height: 70)
                    .opacity(waveOpacity)

                Image(systemName: centerIcon)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .animation(.easeOut(duration: 0.12), value: audioLevel)
            .animation(.easeInOut(duration: 0.25), value: phase)
        }
    }

    private var centerIcon: String {
        switch phase {
        case .off:
            return "mic.slash.fill"
        case .connecting, .speechDetected:
            return "dot.radiowaves.left.and.right"
        case .quiet:
            return "ear"
        case .transcribing:
            return "waveform"
        case .finalizing:
            return "hourglass"
        case .sending:
            return "paperplane.fill"
        case .attention:
            return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch phase {
        case .off:
            return .secondary
        case .connecting, .speechDetected, .finalizing:
            return .orange
        case .quiet:
            return .green
        case .transcribing:
            return .blue
        case .sending:
            return .teal
        case .attention:
            return .red
        }
    }

    private var baseColor: Color {
        switch phase {
        case .off:
            return Color(.tertiarySystemFill)
        default:
            return accentColor
        }
    }

    private var baseOpacity: Double {
        switch phase {
        case .off:
            return 0.32
        case .quiet:
            return 0.12
        case .attention:
            return 0.14
        default:
            return 0.18
        }
    }

    private var ringOpacity: Double {
        switch phase {
        case .off:
            return 0.18
        case .quiet:
            return 0.28
        default:
            return 0.54
        }
    }

    private var waveOpacity: Double {
        switch phase {
        case .transcribing, .speechDetected:
            return 1
        case .quiet:
            return 0.35
        default:
            return 0
        }
    }

    private var speed: Double {
        switch phase {
        case .transcribing:
            return 5.4
        case .speechDetected, .finalizing, .sending:
            return 3.0
        default:
            return 1.6
        }
    }

    private var pulseScale: CGFloat {
        switch phase {
        case .quiet:
            return 0.015
        case .off:
            return 0
        default:
            return 0.035
        }
    }

    private var ringScale: CGFloat {
        switch phase {
        case .quiet:
            return 0.012
        case .off:
            return 0
        default:
            return 0.035
        }
    }
}

private struct WaveBars: View {
    let level: CGFloat
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.68))
                    .frame(width: 7, height: height(for: index))
            }
        }
    }

    private func height(for index: Int) -> CGFloat {
        let base: [CGFloat] = [20, 34, 48, 62, 48, 34, 20]
        let quiet = base[index] * 0.42
        return quiet + base[index] * max(0.12, level)
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: DictationViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("keyboardSetupTipDismissed") private var keyboardSetupTipDismissed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    outputsSection
                    engineSection
                    keyboardSection
                    diagnosticsSection
                    if viewModel.usesDeepgram && !viewModel.speakerLabels.seenIDs.isEmpty {
                        speakersSection
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var outputsSection: some View {
        SettingsSection(title: "Send") {
            Toggle(isOn: $viewModel.streamToWebhook) {
                Label("Webhook", systemImage: "antenna.radiowaves.left.and.right")
            }

            TextField("Webhook URL", text: $viewModel.webhookURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)

            SecureField("Bearer token", text: $viewModel.webhookToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $viewModel.autoInsertOnKeyboardOpen) {
                Label("Keyboard auto-insert", systemImage: "keyboard")
            }

            Toggle(isOn: $viewModel.pressReturnAfterSend) {
                Label("Press return after send", systemImage: "return")
            }

            Toggle(isOn: $viewModel.autoStartListening) {
                Label("Auto-start on open", systemImage: "bolt.fill")
            }
        }
    }

    private var engineSection: some View {
        SettingsSection(title: "Engine") {
            Picker("Engine", selection: $viewModel.backend) {
                ForEach(DictationBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRecording)

            if viewModel.usesDeepgram {
                HStack(spacing: 10) {
                    SecureField("Deepgram API key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(viewModel.saveAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        viewModel.saveAPIKey()
                    } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 38, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Save API key")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Thought pause", systemImage: "timer")
                        Spacer()
                        Text(String(format: "%.1fs", viewModel.thoughtPauseSeconds))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.semibold))

                    Slider(value: $viewModel.thoughtPauseSeconds, in: 2.0...6.0, step: 0.25)
                }
            }
        }
    }

    private var keyboardSection: some View {
        SettingsSection(title: "Keyboard") {
            if !keyboardSetupTipDismissed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Add Yappatron Keyboard in iOS Keyboard settings.", systemImage: "1.circle.fill")
                    Label("Turn on Allow Full Access for live insertion.", systemImage: "2.circle.fill")
                    Label("Start here, then swipe back to the input.", systemImage: "3.circle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                HStack {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)

                    Button("Dismiss") {
                        keyboardSetupTipDismissed = true
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Keyboard Settings", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var diagnosticsSection: some View {
        SettingsSection(title: "Diagnostics") {
            HStack(spacing: 14) {
                Label("\(viewModel.deliveredUtteranceCount)", systemImage: "paperplane")
                Label("\(viewModel.webhookPostsSucceeded)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(viewModel.webhookPostsFailed)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)

            if let error = viewModel.lastWebhookError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !viewModel.lastDeliveredText.isEmpty {
                Text(viewModel.lastDeliveredText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            HStack {
                Button {
                    viewModel.copyTranscript()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canShareTranscript)

                Button(role: .destructive) {
                    viewModel.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canShareTranscript || viewModel.isRecording)
            }

            ForEach(viewModel.outputEvents.prefix(4)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: outputEventIconName(for: event.status))
                        .foregroundStyle(outputEventColor(for: event.status))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(event.destination.rawValue) \(event.status.rawValue)")
                            .font(.caption.weight(.semibold))
                        Text(event.text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var speakersSection: some View {
        SettingsSection(title: "Speakers") {
            ForEach(viewModel.speakerLabels.seenIDs, id: \.self) { id in
                SpeakerRenameRow(
                    speakerID: id,
                    currentName: viewModel.speakerLabels.name(for: id),
                    onSave: { newName in
                        viewModel.speakerLabels.setName(newName, for: id)
                        viewModel.objectWillChange.send()
                    }
                )
            }
        }
    }

    private func outputEventIconName(for status: TranscriptOutputStatus) -> String {
        switch status {
        case .queued:
            return "tray.fill"
        case .sending:
            return "paperplane.fill"
        case .retrying:
            return "arrow.clockwise"
        case .sent:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private func outputEventColor(for status: TranscriptOutputStatus) -> Color {
        switch status {
        case .queued:
            return .secondary
        case .sending, .retrying:
            return .orange
        case .sent:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SpeakerRenameRow: View {
    let speakerID: Int
    let currentName: String
    let onSave: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Speaker \(speakerID)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 88, alignment: .leading)

            TextField(currentName, text: $draft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit {
                    onSave(draft)
                    focused = false
                }
                .onAppear {
                    if draft.isEmpty && !currentName.hasPrefix("Speaker ") {
                        draft = currentName
                    }
                }
                .textFieldStyle(.roundedBorder)

            Button {
                onSave(draft)
                focused = false
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

#Preview {
    ContentView()
}
