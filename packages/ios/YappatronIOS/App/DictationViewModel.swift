import Foundation
import UIKit

enum DictationBackend: String, CaseIterable, Identifiable {
    case local
    case deepgram

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .deepgram:
            return "Deepgram"
        }
    }
}

@MainActor
final class DictationViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case listening
        case finishing
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Ready"
            case .connecting:
                return "Connecting"
            case .listening:
                return "Listening"
            case .finishing:
                return "Finishing"
            case .failed:
                return "Needs attention"
            }
        }
    }

    @Published var backend: DictationBackend {
        didSet {
            defaults.set(backend.rawValue, forKey: DefaultsKeys.backend)
        }
    }
    @Published var apiKey: String
    @Published private(set) var transcript = ""
    @Published private(set) var status: Status = .idle
    @Published var autoInsertOnKeyboardOpen: Bool {
        didSet {
            sharedStore.autoInsertOnKeyboardOpen = autoInsertOnKeyboardOpen
        }
    }
    @Published var copiedConfirmationVisible = false

    // MARK: - Webhook streaming
    @Published var webhookURL: String {
        didSet { defaults.set(webhookURL, forKey: DefaultsKeys.webhookURL) }
    }
    @Published var webhookToken: String {
        didSet { defaults.set(webhookToken, forKey: DefaultsKeys.webhookToken) }
    }
    @Published var streamToWebhook: Bool {
        didSet { defaults.set(streamToWebhook, forKey: DefaultsKeys.streamToWebhook) }
    }
    @Published private(set) var lastWebhookError: String?
    @Published private(set) var webhookPostsSucceeded: Int = 0
    @Published private(set) var webhookPostsFailed: Int = 0

    let speakerLabels = SpeakerLabelStore()
    private let webhookClient = WebhookClient()
    private var currentSessionID = UUID().uuidString

    var isRecording: Bool {
        status == .connecting || status == .listening || status == .finishing
    }

    var canShareTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesDeepgram: Bool {
        backend == .deepgram
    }

    private let audioCapture = AudioCaptureManager()
    private let sharedStore = SharedTranscriptStore.shared
    private let defaults = UserDefaults.standard

    private var localRecognizer: LocalSpeechRecognizer?
    private var deepgramClient: DeepgramStreamingClient?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var audioSendTask: Task<Void, Never>?

    private enum DefaultsKeys {
        static let backend = "dictationBackend"
        static let webhookURL = "webhookURL"
        static let webhookToken = "webhookToken"
        static let streamToWebhook = "streamToWebhook"
    }

    init() {
        backend = DictationBackend(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.backend) ?? "") ?? .local
        apiKey = KeychainStore.loadAPIKey()
        autoInsertOnKeyboardOpen = sharedStore.autoInsertOnKeyboardOpen
        transcript = sharedStore.latestTranscript().text
        webhookURL = UserDefaults.standard.string(forKey: DefaultsKeys.webhookURL) ?? ""
        webhookToken = UserDefaults.standard.string(forKey: DefaultsKeys.webhookToken) ?? ""
        streamToWebhook = UserDefaults.standard.bool(forKey: DefaultsKeys.streamToWebhook)

        webhookClient.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.webhookPostsSucceeded += 1
                    self.lastWebhookError = nil
                case .failure(let error):
                    self.webhookPostsFailed += 1
                    self.lastWebhookError = error.localizedDescription
                }
            }
        }
    }

    func saveAPIKey() {
        do {
            try KeychainStore.saveAPIKey(apiKey)
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func toggleRecording() {
        if isRecording {
            Task {
                await stopRecording()
            }
        } else {
            Task {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        guard !isRecording else {
            return
        }

        do {
            try KeychainStore.saveAPIKey(apiKey)
            transcript = ""
            sharedStore.clearTranscript(removePasteboard: false)

            // Fresh session ID per recording so the consumer can correlate
            // utterances within the same conversation and segment across
            // record/pause/record cycles.
            currentSessionID = UUID().uuidString
            webhookPostsSucceeded = 0
            webhookPostsFailed = 0
            lastWebhookError = nil

            status = .connecting

            switch backend {
            case .local:
                try await startLocalRecording()
            case .deepgram:
                try await startDeepgramRecording()
            }

            status = .listening
        } catch {
            await cleanUpRecording()
            status = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard isRecording else {
            return
        }

        status = .finishing

        if let localRecognizer {
            let finalText = await localRecognizer.stop()
            receiveTranscript(finalText)
            self.localRecognizer = nil
            status = .idle
            return
        }

        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil

        try? await Task.sleep(nanoseconds: 250_000_000)
        await audioSendTask?.value

        let finalText = (try? await deepgramClient?.finish()) ?? transcript
        receiveTranscript(finalText)

        audioSendTask = nil
        await deepgramClient?.disconnect()
        deepgramClient = nil

        status = .idle
    }

    func copyTranscript() {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return
        }

        sharedStore.saveTranscript(trimmedTranscript)
        copiedConfirmationVisible = true

        Task {
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            await MainActor.run {
                copiedConfirmationVisible = false
            }
        }
    }

    func clearTranscript() {
        transcript = ""
        sharedStore.clearTranscript(removePasteboard: true)
    }

    private func receiveTranscript(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = trimmedText
        sharedStore.saveTranscript(trimmedText)
    }

    private func handleDiarizedFinal(_ runs: [DiarizedRun]) {
        for run in runs {
            if run.speakerID >= 0 {
                speakerLabels.recordSeen(run.speakerID)
            }
        }

        guard streamToWebhook, !webhookURL.isEmpty else { return }

        for run in runs {
            let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let speakerName: String?
            if run.speakerID >= 0 {
                speakerName = speakerLabels.name(for: run.speakerID)
            } else {
                speakerName = nil
            }

            let utterance = DiarizedUtterance(
                session_id: currentSessionID,
                speaker: speakerName,
                speaker_id: run.speakerID >= 0 ? run.speakerID : nil,
                text: trimmed,
                start_ms: Int(run.startSec * 1000),
                end_ms: Int(run.endSec * 1000),
                is_final: true
            )
            webhookClient.send(utterance, to: webhookURL, bearerToken: webhookToken.isEmpty ? nil : webhookToken)
        }
    }

    private func startLocalRecording() async throws {
        let recognizer = LocalSpeechRecognizer()
        recognizer.onTranscript = { [weak self] text, _ in
            Task { @MainActor in
                self?.receiveTranscript(text)
            }
        }
        recognizer.onError = { [weak self] message in
            Task { @MainActor in
                self?.status = .failed(message)
            }
        }

        try await recognizer.start()
        localRecognizer = recognizer
    }

    private func startDeepgramRecording() async throws {
        let client = DeepgramStreamingClient(apiKey: apiKey)
        client.onTranscript = { [weak self] text, _ in
            Task { @MainActor in
                self?.receiveTranscript(text)
            }
        }
        client.onDiarizedFinal = { [weak self] runs in
            Task { @MainActor in
                self?.handleDiarizedFinal(runs)
            }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in
                self?.status = .failed(message)
            }
        }

        try await client.connect()
        deepgramClient = client

        let stream = AsyncStream<Data>.makeStream()
        audioContinuation = stream.continuation

        audioSendTask = Task { [weak client] in
            for await chunk in stream.stream {
                guard !Task.isCancelled else {
                    break
                }

                do {
                    try await client?.sendAudio(chunk)
                } catch {
                    await MainActor.run { [weak self] in
                        self?.status = .failed(error.localizedDescription)
                    }
                    break
                }
            }
        }

        let audioContinuation = stream.continuation
        try await audioCapture.start { data in
            audioContinuation.yield(data)
        }
    }

    private func cleanUpRecording() async {
        if let localRecognizer {
            _ = await localRecognizer.stop()
            self.localRecognizer = nil
        }

        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        await deepgramClient?.disconnect()
        deepgramClient = nil
    }
}
