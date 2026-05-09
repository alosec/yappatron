import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DictationViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroSection
                    outputsSection
                    engineSection
                    liveSection
                    if viewModel.usesDeepgram && !viewModel.speakerLabels.seenIDs.isEmpty {
                        speakersSection
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Yappatron")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: viewModel.transcript) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.canShareTranscript)
                }
            }
            .onAppear {
                viewModel.autoStartIfNeeded()
            }
            .onChange(of: viewModel.autoStartListening) { _, _ in
                viewModel.autoStartIfNeeded()
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Label(viewModel.status.label, systemImage: statusIconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)

                Spacer()

                Text(viewModel.outputSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                viewModel.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(recordButtonColor)
                        .frame(width: 178, height: 178)
                        .shadow(color: recordButtonColor.opacity(0.24), radius: 22, y: 12)

                    VStack(spacing: 10) {
                        Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 42, weight: .bold))
                        Text(viewModel.recordButtonTitle)
                            .font(.headline.weight(.bold))
                            .multilineTextAlignment(.center)
                            .frame(width: 122)
                    }
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.status == .connecting || viewModel.status == .finishing)

            if !viewModel.lastDeliveredText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Last send", systemImage: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(viewModel.lastDeliveredText)
                        .font(.body)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send To")
                .font(.headline)

            Toggle(isOn: $viewModel.streamToWebhook) {
                Label("Webhook", systemImage: "antenna.radiowaves.left.and.right")
            }
            .toggleStyle(.switch)

            TextField("Webhook URL", text: $viewModel.webhookURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            SecureField("Bearer token", text: $viewModel.webhookToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Toggle(isOn: $viewModel.autoInsertOnKeyboardOpen) {
                Label("Keyboard auto-insert", systemImage: "keyboard")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $viewModel.pressReturnAfterSend) {
                Label("Press return after send", systemImage: "return")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $viewModel.autoStartListening) {
                Label("Auto-start on app open", systemImage: "bolt.fill")
            }
            .toggleStyle(.switch)

            if let error = viewModel.lastWebhookError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine")
                .font(.headline)

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
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button {
                        viewModel.saveAPIKey()
                    } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Save API key")
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Live")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.copyTranscript()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(!viewModel.canShareTranscript)
                .accessibilityLabel("Copy transcript")

                Button(role: .destructive) {
                    viewModel.clearTranscript()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!viewModel.canShareTranscript || viewModel.isRecording)
                .accessibilityLabel("Clear transcript")
            }

            Text(viewModel.transcript.isEmpty ? " " : viewModel.transcript)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Label("\(viewModel.deliveredUtteranceCount)", systemImage: "paperplane")
                Label("\(viewModel.webhookPostsSucceeded)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(viewModel.webhookPostsFailed)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name Speakers")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(viewModel.speakerLabels.seenIDs, id: \.self) { id in
                    SpeakerRenameRow(
                        speakerID: id,
                        currentName: viewModel.speakerLabels.name(for: id),
                        onSave: { newName in
                            viewModel.speakerLabels.setName(newName, for: id)
                            viewModel.objectWillChange.send()
                        }
                    )
                    if id != viewModel.speakerLabels.seenIDs.last {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusIconName: String {
        switch viewModel.status {
        case .idle:
            return "checkmark.circle"
        case .connecting:
            return "bolt.horizontal.circle"
        case .listening:
            return "waveform.circle.fill"
        case .finishing:
            return "hourglass.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .idle:
            return .secondary
        case .connecting, .finishing:
            return .orange
        case .listening:
            return .red
        case .failed:
            return .red
        }
    }

    private var recordButtonColor: Color {
        viewModel.isRecording ? .red : .blue
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

            Button {
                onSave(draft)
                focused = false
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview {
    ContentView()
}
