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

    enum ListeningPhase: Equatable {
        case off
        case connecting
        case quiet
        case speechDetected
        case transcribing
        case finalizing
        case sending
        case attention(String)

        var title: String {
            switch self {
            case .off:
                return "Off"
            case .connecting:
                return "Connecting"
            case .quiet:
                return "Quiet"
            case .speechDetected:
                return "Heard you"
            case .transcribing:
                return "Transcribing"
            case .finalizing:
                return "Finalizing"
            case .sending:
                return "Sending"
            case .attention:
                return "Needs attention"
            }
        }

        var detail: String {
            switch self {
            case .off:
                return "Tap to arm"
            case .connecting:
                return "Preparing the mic"
            case .quiet:
                return "Waiting for speech"
            case .speechDetected:
                return "Opening the stream"
            case .transcribing:
                return "Speech detected"
            case .finalizing:
                return "Finding the end"
            case .sending:
                return "Delivering"
            case .attention(let message):
                return message
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
    @Published private(set) var listeningPhase: ListeningPhase = .off
    @Published private(set) var audioLevel: Double = 0
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
        didSet {
            defaults.set(streamToWebhook, forKey: DefaultsKeys.streamToWebhook)
            if streamToWebhook && !oldValue {
                lastWebhookStreamedTranscript = transcript
            }
        }
    }
    @Published private(set) var lastWebhookError: String?
    @Published private(set) var webhookPostsSucceeded: Int = 0
    @Published private(set) var webhookPostsFailed: Int = 0
    @Published private(set) var outputEvents: [TranscriptOutputEvent] = []
    @Published private(set) var deliveredUtteranceCount: Int = 0
    @Published private(set) var lastDeliveredText: String = ""
    @Published var thoughtPauseSeconds: Double {
        didSet { defaults.set(thoughtPauseSeconds, forKey: DefaultsKeys.thoughtPauseSeconds) }
    }
    @Published var keyboardLaunchMessageVisible = false

    let speakerLabels = SpeakerLabelStore()
    private let webhookOutbox = WebhookOutbox()
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
    private var recordingBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastKeyboardCommandAt: TimeInterval = 0
    private var lastDictationStatePublishedAt: TimeInterval = 0
    private var lastDeliveredLocalTranscript = ""
    private var sessionStartedAt = Date()
    private var lastDeliveryDate = Date()
    private var outputSequence = 0
    private var lastWebhookStreamedTranscript = ""
    private var webhookStreamSequence = 0
    private var deepgramTranscriptPrefix = ""
    private var deepgramConnectTask: Task<Void, Never>?
    private var deepgramFinishTask: Task<Void, Never>?
    private var phaseResetTask: Task<Void, Never>?
    private var preRollChunks: [Data] = []
    private var bufferedDeepgramChunks: [Data] = []
    private var speechHitCount = 0
    private var lastSpeechDetectedAt: Date?
    private var isDeepgramArmed = false
    private var isDeepgramOpening = false
    private var isDeepgramFinalizing = false
    private var didAutoStart = false

    private let speechStartThreshold = 0.012
    private let speechContinueThreshold = 0.007
    private let preRollChunkLimit = 8
    private let speechStartHitThreshold = 2

    private enum DefaultsKeys {
        static let backend = "dictationBackend"
        static let webhookURL = "webhookURL"
        static let webhookToken = "webhookToken"
        static let streamToWebhook = "streamToWebhook"
        static let pressReturnAfterSend = "pressReturnAfterSend"
        static let autoStartListening = "autoStartListening"
        static let thoughtPauseSeconds = "thoughtPauseSeconds"
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
        let savedThoughtPause = UserDefaults.standard.double(forKey: DefaultsKeys.thoughtPauseSeconds)
        thoughtPauseSeconds = savedThoughtPause > 0 ? savedThoughtPause : 3.5
        sharedStore.pressReturnAfterInsert = pressReturnAfterSend
        publishDictationState()
        configureLifecycleObservers()

        webhookOutbox.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event.status {
                case .sent:
                    self.webhookPostsSucceeded += 1
                    self.lastWebhookError = nil
                case .failed:
                    self.webhookPostsFailed += 1
                    self.lastWebhookError = event.detail
                case .queued, .sending, .retrying:
                    break
                }
                self.upsertOutputEvent(event)
            }
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configureLifecycleObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginRecordingBackgroundTaskIfNeeded()
            }
        })

        notificationObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endRecordingBackgroundTask()
                self?.publishDictationState()
            }
        })
    }

    private func beginRecordingBackgroundTaskIfNeeded() {
        guard isRecording, recordingBackgroundTask == .invalid else {
            return
        }

        publishDictationState()
        recordingBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "YappatronDictation") { [weak self] in
            Task { @MainActor in
                self?.endRecordingBackgroundTask()
            }
        }
    }

    private func endRecordingBackgroundTask() {
        guard recordingBackgroundTask != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(recordingBackgroundTask)
        recordingBackgroundTask = .invalid
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

    private var deepgramCommitPolicy: DeepgramCommitPolicy {
        let mode: DeepgramCommitPolicy.Mode = (streamToWebhook || pressReturnAfterSend) ? .conservative : .responsive
        return .make(mode: mode, thoughtPauseSeconds: thoughtPauseSeconds)
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
            webhookStreamSequence = 0
            lastWebhookStreamedTranscript = ""
            deepgramTranscriptPrefix = ""
            resetSpeechGate()
            lastDeliveredLocalTranscript = ""
            lastDeliveredText = ""
            deliveredUtteranceCount = 0
            webhookPostsSucceeded = 0
            webhookPostsFailed = 0
            lastWebhookError = nil

            status = .connecting
            listeningPhase = .connecting
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
            if listeningPhase == .connecting {
                listeningPhase = .quiet
            }
            publishDictationState()
        } catch {
            await cleanUpRecording()
            status = .failed(error.localizedDescription)
            listeningPhase = .attention(error.localizedDescription)
            publishDictationState()
        }
    }

    func stopRecording() async {
        guard isRecording else {
            return
        }

        status = .finishing
        listeningPhase = .finalizing
        UIApplication.shared.isIdleTimerDisabled = false
        endRecordingBackgroundTask()
        publishDictationState()

        if let localRecognizer {
            localDeliveryTask?.cancel()
            let finalText = await localRecognizer.stop()
            receiveTranscript(finalText)
            deliverLocalTranscriptIfNeeded(finalText, force: true)
            self.localRecognizer = nil
            status = .idle
            listeningPhase = .off
            publishDictationState()
            stopKeyboardCommandPolling()
            return
        }

        isDeepgramArmed = false
        deepgramConnectTask?.cancel()
        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil

        try? await Task.sleep(nanoseconds: 250_000_000)
        await audioSendTask?.value

        if let deepgramClient {
            let finalText = (try? await deepgramClient.finish()) ?? ""
            receiveDeepgramTranscript(finalText, streamWebhookUpdate: true)
            await deepgramClient.disconnect()
        }
        await deepgramFinishTask?.value

        audioSendTask = nil
        deepgramClient = nil
        isDeepgramOpening = false
        isDeepgramFinalizing = false
        resetSpeechGate()

        status = .idle
        listeningPhase = .off
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

    private func receiveTranscript(_ text: String, streamWebhookUpdate: Bool = false) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = trimmedText
        if isRecording,
           !trimmedText.isEmpty,
           listeningPhase != .finalizing,
           listeningPhase != .sending {
            listeningPhase = .transcribing
        }
        if streamWebhookUpdate {
            streamWebhookTranscriptIfNeeded(trimmedText)
        }
        publishDictationState()
    }

    private func receiveDeepgramTranscript(_ text: String, streamWebhookUpdate: Bool = false) {
        receiveTranscript(fullDeepgramTranscript(for: text), streamWebhookUpdate: streamWebhookUpdate)
    }

    private func fullDeepgramTranscript(for segmentTranscript: String) -> String {
        let prefix = deepgramTranscriptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = segmentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if prefix.isEmpty { return segment }
        if segment.isEmpty { return prefix }
        if prefix == segment || prefix.hasSuffix(segment) { return prefix }

        return "\(prefix) \(segment)"
    }

    private var hasWebhookEndpoint: Bool {
        streamToWebhook && !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var webhookBearerToken: String? {
        let token = webhookToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func streamWebhookTranscriptIfNeeded(_ fullTranscript: String) {
        guard hasWebhookEndpoint, isRecording else { return }

        let normalized = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let rawDelta = appendOnlyDelta(from: lastWebhookStreamedTranscript, to: normalized)
        let appendText = normalizedWebhookAppendText(rawDelta, after: lastWebhookStreamedTranscript)
        lastWebhookStreamedTranscript = normalized

        guard !appendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        webhookStreamSequence += 1
        let now = Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
        let utterance = DiarizedUtterance(
            event_type: "stream_delta",
            event_id: "\(currentSessionID)-stream-\(webhookStreamSequence)",
            session_id: currentSessionID,
            speaker: nil,
            speaker_id: nil,
            text: appendText,
            append_text: appendText,
            formatted_text: nil,
            start_ms: now,
            end_ms: now,
            is_final: false,
            source: backend.rawValue,
            sequence: nil,
            should_press_return: false,
            commit_reason: nil,
            runs: nil
        )
        webhookOutbox.sendTransient(utterance, to: webhookURL, bearerToken: webhookBearerToken)
    }

    private func finalWebhookAppendText(fullTranscript: String, suffix: String) -> String? {
        guard hasWebhookEndpoint else { return nil }

        let normalized = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDelta = appendOnlyDelta(from: lastWebhookStreamedTranscript, to: normalized)
        let appendText = normalizedWebhookAppendText(rawDelta, after: lastWebhookStreamedTranscript)
        lastWebhookStreamedTranscript = normalized
        return appendText + suffix
    }

    private func appendOnlyDelta(from previous: String, to current: String) -> String {
        guard !current.isEmpty else { return "" }
        guard !previous.isEmpty else { return current }

        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }

        if current.count > previous.count {
            return String(current.dropFirst(previous.count))
        }

        return ""
    }

    private func normalizedWebhookAppendText(_ rawDelta: String, after previous: String) -> String {
        guard !rawDelta.isEmpty else { return "" }

        if previous.isEmpty {
            return rawDelta.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let first = rawDelta.first,
              let lastPrevious = previous.last,
              !first.isWhitespace,
              !lastPrevious.isWhitespace,
              first.isLetter || first.isNumber else {
            return rawDelta
        }

        return " \(rawDelta)"
    }

    private func handleDiarizedFinal(_ turn: DeepgramDiarizedTurn) {
        let runs = turn.runs
        for run in runs {
            if run.speakerID >= 0 {
                speakerLabels.recordSeen(run.speakerID)
            }
        }

        let cleanedRuns = runs.compactMap { run -> DiarizedRun? in
            let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return DiarizedRun(
                speakerID: run.speakerID,
                text: trimmed,
                startSec: run.startSec,
                endSec: run.endSec
            )
        }
        guard !cleanedRuns.isEmpty else { return }

        outputSequence += 1
        let text = cleanedRuns.map(\.text).joined(separator: " ")
        let runPayloads = cleanedRuns.map { run in
            DiarizedUtteranceRun(
                speaker: speakerName(for: run.speakerID),
                speaker_id: run.speakerID >= 0 ? run.speakerID : nil,
                text: run.text,
                start_ms: Int(run.startSec * 1000),
                end_ms: Int(run.endSec * 1000)
            )
        }
        let suffix = speakerSuffixText(for: cleanedRuns)
        let fullTranscript = fullDeepgramTranscript(for: turn.fullTranscript)
        let appendText = finalWebhookAppendText(fullTranscript: fullTranscript, suffix: suffix)
        deepgramTranscriptPrefix = fullTranscript

        let utterance = DiarizedUtterance(
            event_type: "utterance_end",
            event_id: makeOutputEventID(sequence: outputSequence),
            session_id: currentSessionID,
            speaker: singleSpeakerName(in: cleanedRuns),
            speaker_id: singleSpeakerID(in: cleanedRuns),
            text: text,
            append_text: appendText,
            formatted_text: formattedText(text: text, suffix: suffix),
            start_ms: runPayloads.map(\.start_ms).min() ?? 0,
            end_ms: runPayloads.map(\.end_ms).max() ?? 0,
            is_final: true,
            source: backend.rawValue,
            sequence: outputSequence,
            should_press_return: streamToWebhook ? true : pressReturnAfterSend,
            commit_reason: turn.reason.rawValue,
            runs: runPayloads
        )
        deliver(utterance)
    }

    private func makeOutputEventID(sequence: Int) -> String {
        "\(currentSessionID)-\(sequence)"
    }

    private func speakerName(for speakerID: Int) -> String? {
        speakerID >= 0 ? speakerLabels.name(for: speakerID) : nil
    }

    private func singleSpeakerID(in runs: [DiarizedRun]) -> Int? {
        let speakerIDs = Set(runs.map(\.speakerID).filter { $0 >= 0 })
        return speakerIDs.count == 1 ? speakerIDs.first : nil
    }

    private func singleSpeakerName(in runs: [DiarizedRun]) -> String? {
        guard let speakerID = singleSpeakerID(in: runs) else {
            return nil
        }
        return speakerName(for: speakerID)
    }

    private func speakerSuffixText(for runs: [DiarizedRun]) -> String {
        let labels = runs.reduce(into: [String]()) { labels, run in
            guard let speaker = speakerName(for: run.speakerID), !labels.contains(speaker) else {
                return
            }
            labels.append(speaker)
        }

        guard !labels.isEmpty else {
            return "\n"
        }

        return "\n[\(labels.joined(separator: " -> "))]\n"
    }

    private func formattedText(text: String, suffix: String) -> String? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }

        if suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanedText
        }

        return cleanedText + suffix
    }

    private func startLocalRecording() async throws {
        let recognizer = LocalSpeechRecognizer()
        recognizer.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                self.receiveTranscript(text, streamWebhookUpdate: isFinal)
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
        listeningPhase = .quiet
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
        let appendText = finalWebhookAppendText(fullTranscript: fullTranscript, suffix: "\n")
        outputSequence += 1
        let utterance = DiarizedUtterance(
            event_type: "utterance_end",
            event_id: makeOutputEventID(sequence: outputSequence),
            session_id: currentSessionID,
            speaker: nil,
            speaker_id: nil,
            text: trimmedChunk,
            append_text: appendText,
            formatted_text: nil,
            start_ms: Int(lastDeliveryDate.timeIntervalSince(sessionStartedAt) * 1000),
            end_ms: Int(now.timeIntervalSince(sessionStartedAt) * 1000),
            is_final: true,
            source: backend.rawValue,
            sequence: outputSequence,
            should_press_return: streamToWebhook ? true : pressReturnAfterSend,
            commit_reason: DeepgramCommitReason.localFinal.rawValue,
            runs: nil
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
            webhookOutbox: webhookOutbox
        )

        deliveredUtteranceCount += 1
        lastDeliveredText = utterance.formatted_text ?? utterance.text
        listeningPhase = .sending
        scheduleQuietPhaseReset(after: 0.9)
        prependOutputEvents(events)
    }

    private func prependOutputEvents(_ events: [TranscriptOutputEvent]) {
        guard !events.isEmpty else { return }
        events.reversed().forEach(upsertOutputEvent)
    }

    private func prependOutputEvent(_ event: TranscriptOutputEvent) {
        upsertOutputEvent(event)
    }

    private func upsertOutputEvent(_ event: TranscriptOutputEvent) {
        if let index = outputEvents.firstIndex(where: { $0.id == event.id }) {
            outputEvents[index] = event
        } else {
            outputEvents.insert(event, at: 0)
        }

        if outputEvents.count > 12 {
            outputEvents.removeLast(outputEvents.count - 12)
        }
    }

    private func startDeepgramRecording() async throws {
        isDeepgramArmed = true
        listeningPhase = .quiet

        try await audioCapture.start { [weak self] chunk in
            Task { @MainActor in
                self?.handleDeepgramCapturedChunk(chunk)
            }
        }
    }

    private func handleDeepgramCapturedChunk(_ chunk: CapturedAudioChunk) {
        guard isDeepgramArmed else { return }

        updateAudioLevel(chunk.rmsLevel)
        let isSpeech = chunk.rmsLevel >= speechContinueThreshold

        if isSpeech {
            lastSpeechDetectedAt = Date()
            speechHitCount += 1
        } else {
            speechHitCount = max(0, speechHitCount - 1)
        }

        if deepgramClient == nil && !isDeepgramOpening && !isDeepgramFinalizing {
            appendPreRoll(chunk.data)
            if chunk.rmsLevel >= speechStartThreshold && speechHitCount >= speechStartHitThreshold {
                bufferedDeepgramChunks = preRollChunks
                preRollChunks.removeAll(keepingCapacity: true)
                listeningPhase = .speechDetected
                openDeepgramSegment()
            }
            return
        }

        if isDeepgramOpening {
            bufferedDeepgramChunks.append(chunk.data)
            return
        }

        if isDeepgramFinalizing {
            appendPreRoll(chunk.data)
            return
        }

        audioContinuation?.yield(chunk.data)
        if isSpeech {
            listeningPhase = .transcribing
        } else if let lastSpeechDetectedAt,
                  Date().timeIntervalSince(lastSpeechDetectedAt) >= thoughtPauseSeconds {
            finishDeepgramSegment()
        }
    }

    private func appendPreRoll(_ data: Data) {
        preRollChunks.append(data)
        if preRollChunks.count > preRollChunkLimit {
            preRollChunks.removeFirst(preRollChunks.count - preRollChunkLimit)
        }
    }

    private func updateAudioLevel(_ rmsLevel: Double) {
        let normalized = min(1, max(0, rmsLevel * 28))
        audioLevel = audioLevel * 0.72 + normalized * 0.28
    }

    private func openDeepgramSegment() {
        guard !isDeepgramOpening, deepgramClient == nil, isDeepgramArmed else {
            return
        }

        isDeepgramOpening = true
        deepgramConnectTask?.cancel()
        deepgramConnectTask = Task { [weak self] in
            guard let self else { return }

            do {
                let client = await MainActor.run { self.makeDeepgramClient() }
                try await client.connect()

                await MainActor.run {
                    guard self.isDeepgramArmed, self.status == .listening else {
                        Task { await client.disconnect() }
                        self.isDeepgramOpening = false
                        return
                    }

                    self.installConnectedDeepgramClient(client)
                }
            } catch {
                await MainActor.run {
                    self.isDeepgramOpening = false
                    self.bufferedDeepgramChunks.removeAll(keepingCapacity: true)
                }
                await self.failRecording(error.localizedDescription)
            }
        }
    }

    private func makeDeepgramClient() -> DeepgramStreamingClient {
        let client = DeepgramStreamingClient(apiKey: apiKey, commitPolicy: deepgramCommitPolicy)
        client.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                self?.receiveDeepgramTranscript(text, streamWebhookUpdate: isFinal)
            }
        }
        client.onDiarizedFinal = { [weak self] turn in
            Task { @MainActor in
                self?.handleDiarizedFinal(turn)
            }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in
                await self?.failRecording(message)
            }
        }
        return client
    }

    private func installConnectedDeepgramClient(_ client: DeepgramStreamingClient) {
        deepgramClient = client
        isDeepgramOpening = false
        isDeepgramFinalizing = false

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

        for data in bufferedDeepgramChunks {
            stream.continuation.yield(data)
        }
        bufferedDeepgramChunks.removeAll(keepingCapacity: true)
        listeningPhase = .transcribing
    }

    private func finishDeepgramSegment() {
        guard !isDeepgramFinalizing,
              let client = deepgramClient else {
            return
        }

        listeningPhase = .finalizing
        isDeepgramFinalizing = true
        audioContinuation?.finish()
        audioContinuation = nil
        let sendTask = audioSendTask
        audioSendTask = nil
        deepgramClient = nil

        deepgramFinishTask?.cancel()
        deepgramFinishTask = Task { [weak self, client, sendTask] in
            await sendTask?.value
            let finalText = (try? await client.finish()) ?? ""
            await client.disconnect()

            await MainActor.run {
                guard let self else { return }
                if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.receiveDeepgramTranscript(finalText, streamWebhookUpdate: true)
                }
                self.isDeepgramFinalizing = false
                self.bufferedDeepgramChunks.removeAll(keepingCapacity: true)
                self.resetSpeechGate(keepPreRoll: true)
                if self.isRecording {
                    self.listeningPhase = .quiet
                } else {
                    self.listeningPhase = .off
                }
            }
        }
    }

    private func resetSpeechGate(keepPreRoll: Bool = false) {
        speechHitCount = 0
        lastSpeechDetectedAt = nil
        audioLevel = 0
        bufferedDeepgramChunks.removeAll(keepingCapacity: true)
        if !keepPreRoll {
            preRollChunks.removeAll(keepingCapacity: true)
        }
    }

    private func scheduleQuietPhaseReset(after seconds: Double) {
        phaseResetTask?.cancel()
        phaseResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                guard let self,
                      self.isRecording,
                      self.listeningPhase == .sending else {
                    return
                }
                self.listeningPhase = .quiet
            }
        }
    }

    private func cleanUpRecording() async {
        UIApplication.shared.isIdleTimerDisabled = false
        endRecordingBackgroundTask()
        stopKeyboardCommandPolling()
        localDeliveryTask?.cancel()
        localDeliveryTask = nil
        phaseResetTask?.cancel()
        phaseResetTask = nil
        deepgramConnectTask?.cancel()
        deepgramConnectTask = nil
        deepgramFinishTask?.cancel()
        deepgramFinishTask = nil
        isDeepgramArmed = false

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
        isDeepgramOpening = false
        isDeepgramFinalizing = false
        resetSpeechGate()
        listeningPhase = .off
        publishDictationState(isRecordingOverride: false)
    }

    private func failRecording(_ message: String) async {
        status = .failed(message)
        listeningPhase = .attention(message)
        await cleanUpRecording()
        listeningPhase = .attention(message)
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
