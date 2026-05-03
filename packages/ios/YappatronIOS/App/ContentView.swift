import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DictationViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    backendSection
                    if viewModel.usesDeepgram {
                        apiKeySection
                    }
                    recorderSection
                    transcriptSection
                    keyboardSection
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
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mode")
                .font(.headline)

            Picker("Mode", selection: $viewModel.backend) {
                ForEach(DictationBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRecording)
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deepgram")
                .font(.headline)

            HStack(spacing: 10) {
                SecureField("API key", text: $viewModel.apiKey)
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

    private var recorderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(viewModel.status.label, systemImage: statusIconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)

                Spacer()

                if viewModel.copiedConfirmationVisible {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            Button {
                viewModel.toggleRecording()
            } label: {
                Label(recordButtonTitle, systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRecording ? .red : .blue)

            if case .failed(let message) = viewModel.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
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
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard")
                .font(.headline)

            Toggle(isOn: $viewModel.autoInsertOnKeyboardOpen) {
                Label("Auto-insert latest transcript", systemImage: "keyboard")
            }
            .toggleStyle(.switch)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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

    private var recordButtonTitle: String {
        viewModel.isRecording ? "Stop" : "Record"
    }
}

#Preview {
    ContentView()
}
