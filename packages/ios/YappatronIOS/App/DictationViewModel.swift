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
    @Published var pressReturnAfterSend: Bool {
        didSet {
            defaults.set(pressReturnAfterSend, forKey: DefaultsKeys.pressReturnAfterSend)
            sharedStore.pressReturnAfterInsert = pressReturnAfterSend
        }
    }
    @Published var autoStartListening: Bool {
        didSet {
            defaults.set(autoStartListening, forKey: DefaultsKeys.autoStartListening)
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
    @Published private(set) var outputEvents: [TranscriptOutputEvent] = []
    @Published private(set) var deliveredUtteranceCount: Int = 0
    @Published private(set) var lastDeliveredText: String = ""
    @Published var keyboardLaunchMessageVisible = false

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
    private var localDeliveryTask: Task<Void, Never>?
    private var keyboardCommandTask: Task<Void, Never>?
    private var lastKeyboardCommandAt: TimeInterval = 0
    private var lastDictationStatePublishedAt: TimeInterval = 0
    private var lastDeliveredLocalTranscript = ""
    private var sessionStartedAt = Date()
    private var lastDeliveryDate = Date()
    private var outputSequence = 0
    private var didAutoStart = false

    private enum DefaultsKeys {
        static let backend = "dictationBackend"
        static let webhookURL = "webhookURL"
        static let webhookToken = "webhookToken"
        static let streamToWebhook = "streamToWebhook"
        static let pressReturnAfterSend = "pressReturnAfterSend"
        static let autoStartListening = "autoStartListening"
    }

    init() {
        backend = DictationBackend(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.backend) ?? "") ?? .local
        apiKey = KeychainStore.loadAPIKey()
        autoInsertOnKeyboardOpen = sharedStore.autoInsertOnKeyboardOpen
        pressReturnAfterSend = UserDefaults.standard.bool(forKey: DefaultsKeys.pressReturnAfterSend)
        autoStartListening = UserDefaults.standard.bool(forKey: DefaultsKeys.autoStartListening)
        transcript = sharedStore.latestTranscript().text
        webhookURL = UserDefaults.standard.string(forKey: DefaultsKeys.webhookURL) ?? ""
        webhookToken = UserDefaults.standard.string(forKey: DefaultsKeys.webhookToken) ?? ""
        streamToWebhook = UserDefaults.standard.bool(forKey: DefaultsKeys.streamToWebhook)
        sharedStore.pressReturnAfterInsert = pressReturnAfterSend
        publishDictationState()

        webhookClient.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.webhookPostsSucceeded += 1
                    self.lastWebhookError = nil
                    self.prependOutputEvent(TranscriptOutputEvent(
                        destination: .webhook,
                        status: .sent,
                        text: "Webhook accepted",
                        detail: nil
                    ))
                case .failure(let error):
                    self.webhookPostsFailed += 1
                    self.lastWebhookError = error.localizedDescription
                    self.prependOutputEvent(TranscriptOutputEvent(
                        destination: .webhook,
                        status: .failed,
                        text: error.localizedDescription,
                        detail: nil
                    ))
                }
            }
        }
    }

    var activeOutputLabels: [String] {
        var labels: [String] = []
        if streamToWebhook {
            labels.append("Webhook")
        }
        if autoInsertOnKeyboardOpen {
            labels.append("Keyboard auto")
        } else {
            labels.append("Keyboard ready")
        }
        if pressReturnAfterSend {
            labels.append("Return")
        }
        return labels
    }

    var hasRunnableOutput: Bool {
        true
    }

    var recordButtonTitle: String {
        switch status {
        case .idle, .failed:
            return "Start Listening"
        case .connecting:
            return "Connecting"
        case .listening:
            return "Stop Listening"
        case .finishing:
            return "Finishing"
        }
    }

    var outputSummary: String {
        let labels = activeOutputLabels
        if labels.isEmpty {
            return "No outputs enabled"
        }
        return labels.joined(separator: " + ")
    }

    func autoStartIfNeeded() {
        guard autoStartListening, !didAutoStart, !isRecording else { return }
        didAutoStart = true
        Task {
            await startRecording()
        }
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "yappatron" else { return }

        let parts = [url.host, url.path]
            .compactMap { $0 }
            .joined(separator: "/")

        guard parts.contains("dictation") || parts.contains("start") else {
            return
        }

        keyboardLaunchMessageVisible = true
        if !isRecording {
            Task {
                await startRecording()
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
            outputEvents = []
            sharedStore.clearTranscript(removePasteboard: false)

            // Fresh session ID per recording so the consumer can correlate
            // utterances within the same conversation and segment across
            // record/pause/record cycles.
            currentSessionID = UUID().uuidString
            sessionStartedAt = Date()
            lastDeliveryDate = sessionStartedAt
            outputSequence = 0
            lastDeliveredLocalTranscript = ""
            lastDeliveredText = ""
            deliveredUtteranceCount = 0
            webhookPostsSucceeded = 0
            webhookPostsFailed = 0
            lastWebhookError = nil

            status = .connecting
            UIApplication.shared.isIdleTimerDisabled = true
            publishDictationState()
            startKeyboardCommandPolling()

            switch backend {
            case .local:
                try await startLocalRecording()
            case .deepgram:
                try await startDeepgramRecording()
            }

            status = .listening
            publishDictationState()
        } catch {
            await cleanUpRecording()
            status = .failed(error.localizedDescription)
            publishDictationState()
        }
    }

    func stopRecording() async {
        guard isRecording else {
            return
        }

        status = .finishing
        UIApplication.shared.isIdleTimerDisabled = false
        publishDictationState()

        if let localRecognizer {
            localDeliveryTask?.cancel()
            let finalText = await localRecognizer.stop()
            receiveTranscript(finalText)
            deliverLocalTranscriptIfNeeded(finalText, force: true)
            self.localRecognizer = nil
            status = .idle
            publishDictationState()
            stopKeyboardCommandPolling()
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
        publishDictationState()
        stopKeyboardCommandPolling()
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
        publishDictationState()
    }

    private func handleDiarizedFinal(_ runs: [DiarizedRun]) {
        for run in runs {
            if run.speakerID >= 0 {
                speakerLabels.recordSeen(run.speakerID)
            }
        }

        for run in runs {
            let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let speakerName: String?
            if run.speakerID >= 0 {
                speakerName = speakerLabels.name(for: run.speakerID)
            } else {
                speakerName = nil
            }

            outputSequence += 1
            let utterance = DiarizedUtterance(
                session_id: currentSessionID,
                speaker: speakerName,
                speaker_id: run.speakerID >= 0 ? run.speakerID : nil,
                text: trimmed,
                start_ms: Int(run.startSec * 1000),
                end_ms: Int(run.endSec * 1000),
                is_final: true,
                source: backend.rawValue,
                sequence: outputSequence,
                should_press_return: pressReturnAfterSend
            )
            deliver(utterance)
        }
    }

    private func startLocalRecording() async throws {
        let recognizer = LocalSpeechRecognizer()
        recognizer.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                self.receiveTranscript(text)
                self.scheduleLocalDelivery(for: text, isFinal: isFinal)
            }
        }
        recognizer.onError = { [weak self] message in
            Task { @MainActor in
                await self?.failRecording(message)
            }
        }

        try await recognizer.start()
        localRecognizer = recognizer
    }

    private func scheduleLocalDelivery(for text: String, isFinal: Bool) {
        localDeliveryTask?.cancel()

        if isFinal {
            deliverLocalTranscriptIfNeeded(text, force: true)
            return
        }

        localDeliveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await MainActor.run {
                self?.deliverLocalTranscriptIfNeeded(text, force: false)
            }
        }
    }

    private func deliverLocalTranscriptIfNeeded(_ text: String, force: Bool) {
        let fullTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullTranscript.isEmpty else { return }

        let chunk: String
        if lastDeliveredLocalTranscript.isEmpty {
            chunk = fullTranscript
        } else if fullTranscript.hasPrefix(lastDeliveredLocalTranscript) {
            chunk = String(fullTranscript.dropFirst(lastDeliveredLocalTranscript.count))
        } else if force {
            chunk = fullTranscript
        } else {
            return
        }

        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else { return }

        let now = Date()
        outputSequence += 1
        let utterance = DiarizedUtterance(
            session_id: currentSessionID,
            speaker: nil,
            speaker_id: nil,
            text: trimmedChunk,
            start_ms: Int(lastDeliveryDate.timeIntervalSince(sessionStartedAt) * 1000),
            end_ms: Int(now.timeIntervalSince(sessionStartedAt) * 1000),
            is_final: true,
            source: backend.rawValue,
            sequence: outputSequence,
            should_press_return: pressReturnAfterSend
        )

        deliver(utterance)
        lastDeliveredLocalTranscript = fullTranscript
        lastDeliveryDate = now
    }

    private func deliver(_ utterance: DiarizedUtterance) {
        let events = TranscriptOutputRouter.deliver(
            utterance,
            settings: TranscriptOutputSettings(
                streamToWebhook: streamToWebhook,
                webhookURL: webhookURL,
                webhookToken: webhookToken,
                autoInsertOnKeyboardOpen: autoInsertOnKeyboardOpen,
                pressReturnAfterSend: pressReturnAfterSend
            ),
            sharedStore: sharedStore,
            webhookClient: webhookClient
        )

        deliveredUtteranceCount += 1
        lastDeliveredText = utterance.text
        prependOutputEvents(events)
    }

    private func prependOutputEvents(_ events: [TranscriptOutputEvent]) {
        guard !events.isEmpty else { return }
        outputEvents.insert(contentsOf: events.reversed(), at: 0)
        if outputEvents.count > 12 {
            outputEvents.removeLast(outputEvents.count - 12)
        }
    }

    private func prependOutputEvent(_ event: TranscriptOutputEvent) {
        prependOutputEvents([event])
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
                await self?.failRecording(message)
            }
        }

        try await client.connect()
        deepgramClient = client

        let stream = AsyncStream<Data>.makeStream()
        audioContinuation = stream.continuation

        audioSendTask = Task { [weak client, weak self] in
            for await chunk in stream.stream {
                guard !Task.isCancelled else {
                    break
                }

                do {
                    try await client?.sendAudio(chunk)
                } catch {
                    await self?.failRecording(error.localizedDescription)
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
        UIApplication.shared.isIdleTimerDisabled = false
        stopKeyboardCommandPolling()
        localDeliveryTask?.cancel()
        localDeliveryTask = nil

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
        publishDictationState(isRecordingOverride: false)
    }

    private func failRecording(_ message: String) async {
        status = .failed(message)
        await cleanUpRecording()
        publishDictationState(isRecordingOverride: false)
    }

    private func publishDictationState(isRecordingOverride: Bool? = nil) {
        let updatedAt = Date()
        lastDictationStatePublishedAt = updatedAt.timeIntervalSince1970
        sharedStore.saveDictationState(
            isRecording: isRecordingOverride ?? isRecording,
            liveTranscript: transcript,
            updatedAt: updatedAt
        )
    }

    private func publishDictationHeartbeatIfNeeded() {
        guard isRecording else {
            return
        }

        if Date().timeIntervalSince1970 - lastDictationStatePublishedAt >= 1 {
            publishDictationState()
        }
    }

    private func startKeyboardCommandPolling() {
        keyboardCommandTask?.cancel()
        keyboardCommandTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    self?.handlePendingKeyboardCommand()
                    self?.publishDictationHeartbeatIfNeeded()
                }
            }
        }
    }

    private func stopKeyboardCommandPolling() {
        keyboardCommandTask?.cancel()
        keyboardCommandTask = nil
    }

    private func handlePendingKeyboardCommand() {
        guard let command = sharedStore.latestKeyboardCommand(after: lastKeyboardCommandAt) else {
            return
        }

        lastKeyboardCommandAt = command.updatedAt

        switch command.command {
        case "start":
            if !isRecording {
                Task { await startRecording() }
            }
        case "stop":
            if isRecording {
                Task { await stopRecording() }
            }
        default:
            break
        }
    }
}
