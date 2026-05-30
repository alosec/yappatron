import SwiftUI
import HotKey
import Combine

struct YappatronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // UI
    var statusItem: NSStatusItem!
    var overlayWindow: OverlayWindow?
    var overlayController: OverlayWindowController?
    var focusLockWindow: FocusLockOverlayWindow?
    var focusLockController: FocusLockOverlayWindowController?

    // Core
    var engine: TranscriptionEngine!
    var inputSimulator: InputSimulator!
    var batchProcessor: BatchProcessor?
    var refinementManager: TextRefinementManager?
    let webhookOutbox = WebhookOutbox()

    // Hotkeys
    var togglePauseHotKey: HotKey?
    var toggleOverlayHotKey: HotKey?
    var toggleInputFocusLockHotKey: HotKey?
    var inputFocusLockLocalMonitor: Any?
    var inputFocusLockGlobalMonitor: Any?
    var pushToTalkHotKey: HotKey?
    var pushToTalkLocalMonitor: Any?
    var pushToTalkGlobalMonitor: Any?

    // State
    @Published var isPaused = false
    @Published var isPushToTalkHeld = false
    @Published var currentTypedText = "" // What we've typed so far for append-only updates
    var lockedTextLength = 0             // Characters confirmed by is_final
    var lockedInputFocusTarget: InputSimulator.InputFocusTarget?
    var recentInputFocusTarget: InputSimulator.InputFocusTarget?
    var inputFocusLockAlertVisible = false
    var focusObservationTimer: Timer?
    var lastInputFocusLockShortcutAt = Date.distantPast
    var webhookSessionID = UUID().uuidString
    var webhookSequence = 0
    var lastWebhookStatus = "Idle"

    // Settings
    var pressEnterAfterSpeech: Bool {
        get { UserDefaults.standard.bool(forKey: "pressEnterAfterSpeech") }
        set { UserDefaults.standard.set(newValue, forKey: "pressEnterAfterSpeech") }
    }

    var enableDualPassRefinement: Bool {
        get { UserDefaults.standard.bool(forKey: "enableDualPassRefinement") }
        set { UserDefaults.standard.set(newValue, forKey: "enableDualPassRefinement") }
    }

    var webhookOutputEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "webhookOutputEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "webhookOutputEnabled") }
    }

    var webhookOutputURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "webhookOutputURL") ?? ""
            return stored.isEmpty ? "http://127.0.0.1:3002/input/yappatron" : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "webhookOutputURL") }
    }

    var dictationMode: DictationMode {
        get { DictationMode.current }
        set { DictationMode.current = newValue }
    }

    var indicatorStyle: OverlayViewModel.OrbStyle {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: "indicatorStyle"),
                  let style = OverlayViewModel.OrbStyle(rawValue: rawValue) else {
                return .voronoi
            }

            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "indicatorStyle")
        }
    }

    // Combine
    private var cancellables = Set<AnyCancellable>()

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.setup()
        }
    }

    func setup() async {
        NSApp.setActivationPolicy(.accessory)

        inputSimulator = InputSimulator()

        let backend = STTBackend.current
        engine = TranscriptionEngine(backend: backend)

        // Initialize batch processor and refinement manager if dual-pass is enabled
        // Only for local backend (cloud backends already return punctuated text)
        if enableDualPassRefinement && !backend.returnsPunctuatedText {
            batchProcessor = BatchProcessor()
            if let batchProcessor = batchProcessor {
                refinementManager = TextRefinementManager(
                    batchProcessor: batchProcessor,
                    inputSimulator: inputSimulator
                )

                // Set up refinement completion callback
                refinementManager?.onRefinementComplete = { [weak self] refinedText in
                    self?.handleRefinementComplete(refinedText)
                }

                refinementManager?.applyRefinementTextUpdate = { [weak self] streamedText, refinedText in
                    if self?.webhookOutputEnabled == true {
                        return true
                    }
                    return self?.applyTextUpdateToTypingDestination(from: streamedText, to: refinedText, logRejection: true) ?? false
                }
            }
        }

        webhookOutbox.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleWebhookEvent(event)
            }
        }

        // Request accessibility
        if !InputSimulator.hasAccessibilityPermission() {
            _ = InputSimulator.requestAccessibilityPermissionIfNeeded()
        }

        setupStatusItem()
        setupOverlay()
        setupHotKeys()
        setupEngineCallbacks()
        observeEngineStatus()
        observeHotKeyPreferences()
        startFocusObservation()

        // Initialize batch processor in background (if enabled)
        if let batchProcessor = batchProcessor {
            Task {
                do {
                    try await batchProcessor.initialize()
                    NSLog("[Yappatron] Batch processor ready for dual-pass refinement")
                } catch {
                    NSLog("[Yappatron] Batch processor initialization failed: \(error.localizedDescription)")
                    NSLog("[Yappatron] Falling back to streaming-only mode")
                }
            }
        }

        // Start the engine
        await engine.start()

        if case .ready = engine.status {
            applyDictationModeAfterEngineReady()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            focusObservationTimer?.invalidate()
            unregisterInputFocusLockShortcut()
            webhookOutbox.cancelAll()
            engine.cleanup()
        }
    }

    // MARK: - Typing Destination

    private struct TypingDestination {
        let restoreToken: InputSimulator.InputFocusTarget.RestoreToken?
    }

    @discardableResult
    func withTypingDestination(logRejection: Bool = false, _ work: () -> Void) -> Bool {
        guard let destination = prepareTypingDestination(logRejection: logRejection) else {
            return false
        }

        defer {
            destination.restoreToken?.restore()
        }

        work()
        return true
    }

    func applyTextUpdateToTypingDestination(from oldText: String, to newText: String, logRejection: Bool) -> Bool {
        withTypingDestination(logRejection: logRejection) {
            _ = inputSimulator.applyTextUpdate(from: oldText, to: newText)
        }
    }

    func finishUtteranceTyping() {
        if !currentTypedText.hasSuffix("\n") {
            inputSimulator.typeString(" ")
        }

        if pressEnterAfterSpeech {
            Thread.sleep(forTimeInterval: 0.12)
            inputSimulator.pressEnter()
        }

        currentTypedText = ""
    }

    func sendFinalUtteranceToWebhook(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        webhookSequence += 1
        let payload = TranscriptWebhookPayload(
            text: trimmed,
            sessionID: webhookSessionID,
            sequence: webhookSequence
        )
        lastWebhookStatus = "Queued"
        webhookOutbox.enqueue(payload, to: webhookOutputURL)
        updateStatusIcon()
    }

    func handleWebhookEvent(_ event: WebhookDeliveryEvent) {
        lastWebhookStatus = event.status.rawValue
        if let detail = event.detail {
            NSLog("[Yappatron] Webhook \(event.status.rawValue): \(detail)")
        } else {
            NSLog("[Yappatron] Webhook \(event.status.rawValue)")
        }
        updateStatusIcon()
    }

    private func prepareTypingDestination(logRejection: Bool) -> TypingDestination? {
        if let lockedInputFocusTarget {
            guard let restoreToken = lockedInputFocusTarget.focusForTyping() else {
                handleInputFocusLockLost()
                return nil
            }

            return TypingDestination(restoreToken: restoreToken)
        }

        guard InputSimulator.isTextInputFocused() else {
            if logRejection {
                InputSimulator.logTextInputFocusRejection()
            }
            return nil
        }

        return TypingDestination(restoreToken: nil)
    }

    private func handleInputFocusLockLost() {
        guard let target = lockedInputFocusTarget else { return }

        lockedInputFocusTarget = nil
        currentTypedText = ""
        lockedTextLength = 0
        isPaused = true
        isPushToTalkHeld = false
        engine.stopCapture()
        focusLockWindow?.orderOut(nil)
        updateOverlayStatus()
        updateStatusIcon()

        NSLog("[Yappatron] Input focus lock lost for \(target.displayName); dictation paused")
        showInputFocusLockAlert(
            title: "Input Lock Lost",
            message: "\(target.displayName) is no longer available. Yappatron paused dictation instead of typing into another app."
        )
    }

    private func showInputFocusLockAlert(title: String, message: String) {
        guard !inputFocusLockAlertVisible else { return }

        inputFocusLockAlertVisible = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        inputFocusLockAlertVisible = false
    }

    private func startFocusObservation() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFocusLockUI()
                self?.refreshRecentInputFocusTarget()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        focusObservationTimer = timer
    }

    private func refreshFocusLockUI() {
        guard let target = lockedInputFocusTarget else {
            focusLockWindow?.orderOut(nil)
            return
        }

        guard let frame = target.outlineFrame() else {
            handleInputFocusLockLost()
            return
        }

        focusLockWindow?.show(frame: frame)
    }

    private func refreshRecentInputFocusTarget() {
        guard let target = InputSimulator.captureFocusedTextInputTarget(),
              !target.isCurrentProcess else {
            return
        }

        recentInputFocusTarget = target
    }

    // MARK: - Engine Setup

    func setupEngineCallbacks() {
        // Final transcription (on EOU) - reset for next utterance
        engine.onTranscription = { [weak self] text in
            Task { @MainActor in
                self?.handleFinalTranscription(text)
            }
        }

        // Partial transcription (streaming text) - triggers continuous refinement
        engine.onPartialTranscription = { [weak self] partial in
            Task { @MainActor in
                self?.handlePartialTranscription(partial)
            }
        }

        // Locked text advanced (cloud backends — called on main thread)
        engine.onLockedTextAdvanced = { [weak self] lockedLen in
            self?.lockedTextLength = lockedLen
        }

        // Utterance complete callback - triggers batch refinement (if enabled, local backend only)
        if enableDualPassRefinement && !STTBackend.current.returnsPunctuatedText {
            engine.onUtteranceComplete = { [weak self] audioSamples, streamedText in
                Task { @MainActor in
                    guard self?.webhookOutputEnabled != true else { return }
                    self?.refinementManager?.refineTranscription(
                        audioSamples: audioSamples,
                        streamedText: streamedText
                    )
                }
            }
        }

        engine.onSpeechStart = { [weak self] in
            Task { @MainActor in
                self?.overlayWindow?.overlayViewModel.status = .speaking
                self?.overlayWindow?.overlayViewModel.isSpeaking = true
                self?.updateStatusIcon()
                self?.showOverlay()
            }
        }

        engine.onSpeechEnd = { [weak self] in
            Task { @MainActor in
                self?.updateOverlayStatus()
                self?.overlayWindow?.overlayViewModel.isSpeaking = false
                self?.updateStatusIcon()

                // Auto-hide after a delay
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self?.overlayWindow?.overlayViewModel.isSpeaking == false {
                    self?.overlayWindow?.orderOut(nil)
                }
            }
        }

        engine.onAudioLevel = { [weak self] level in
            self?.overlayWindow?.overlayViewModel.audioLevel = level
        }
    }

    func observeEngineStatus() {
        engine.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateOverlayStatus()
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    func observeHotKeyPreferences() {
        NotificationCenter.default.publisher(for: .pushToTalkHotKeyDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.registerPushToTalkHotKey()
            }
            .store(in: &cancellables)
    }

    /// Handle partial transcription updates (streaming text)
    /// For cloud backends: only types locked append-only text. Interims are display/speech-state only.
    func handlePartialTranscription(_ partial: String) {
        guard !isPaused else { return }
        guard !webhookOutputEnabled else { return }

        if STTBackend.current.returnsPunctuatedText {
            // Cloud backend: only type is_final segments (lockedTextLength matches).
            // Interims flow through for orb/speech detection but aren't typed.
            guard partial.count <= lockedTextLength,
                  partial.count > currentTypedText.count,
                  partial.hasPrefix(currentTypedText) else {
                return
            }

            withTypingDestination {
                let newChars = String(partial.dropFirst(currentTypedText.count))
                if !newChars.isEmpty {
                    inputSimulator.typeString(newChars)
                }
                currentTypedText = partial
            }
            return
        }

        withTypingDestination {
            // Local backend: only append text when the stream extends what was typed.
            if inputSimulator.applyTextUpdate(from: currentTypedText, to: partial) {
                currentTypedText = partial
            }
        }
    }

    /// Handle final transcription (EOU detected)
    /// Behavior depends on dual-pass refinement setting and backend
    func handleFinalTranscription(_ text: String) {
        guard !isPaused else { return }

        if webhookOutputEnabled {
            lockedTextLength = 0
            currentTypedText = ""
            sendFinalUtteranceToWebhook(text)
            return
        }

        withTypingDestination(logRejection: true) {
            // Append any final suffix. Divergent corrections are intentionally ignored.
            if currentTypedText != text {
                if inputSimulator.applyTextUpdate(from: currentTypedText, to: text) {
                    currentTypedText = text
                }
            }

            // Reset locked boundary
            lockedTextLength = 0

            // Cloud backends return punctuated text — no dual-pass needed
            // If dual-pass refinement is DISABLED, add spacing/enter immediately
            // If ENABLED (local only), wait for refinement to complete
            let needsRefinement = enableDualPassRefinement && !STTBackend.current.returnsPunctuatedText
            if !needsRefinement {
                finishUtteranceTyping()
            }
            // If dual-pass enabled, spacing/enter will be added in handleRefinementComplete()
        }
    }

    /// Called after batch refinement completes (dual-pass mode only)
    func handleRefinementComplete(_ refinedText: String) {
        if webhookOutputEnabled {
            currentTypedText = ""
            sendFinalUtteranceToWebhook(refinedText)
            return
        }

        withTypingDestination(logRejection: true) {
            // Only advance tracking when the refinement is an append-only extension.
            if currentTypedText.isEmpty || refinedText.hasPrefix(currentTypedText) {
                currentTypedText = refinedText
            }

            finishUtteranceTyping()
        }
    }

    func updateOverlayStatus() {
        switch engine.status {
        case .initializing:
            overlayWindow?.overlayViewModel.status = .initializing
        case .downloadingModels:
            overlayWindow?.overlayViewModel.status = .downloading(0.5) // Indeterminate
        case .ready:
            overlayWindow?.overlayViewModel.status = (isPaused || dictationMode == .pushToTalk) ? .idle : .listening
        case .listening:
            overlayWindow?.overlayViewModel.status = .listening
        case .error(let msg):
            overlayWindow?.overlayViewModel.status = .error(msg)
        }
    }

    // MARK: - Status Bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yappatron")
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleOverlay()
        }
    }

    func showMenu() {
        let menu = NSMenu()

        // Status
        let statusText: String
        switch engine.status {
        case .initializing: statusText = "⏳ Initializing..."
        case .downloadingModels: statusText = "⬇️ Downloading..."
        case .ready, .listening:
            if isPaused {
                statusText = "⏸ Paused"
            } else if dictationMode == .pushToTalk && engine.status == .ready {
                statusText = "🎙 Push-to-Talk Idle"
            } else if dictationMode == .pushToTalk {
                statusText = "🎙 Push-to-Talk Listening"
            } else {
                statusText = "🎙 Listening"
            }
        case .error(let msg): statusText = "❌ \(msg)"
        }

        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Show current backend
        let backendLabel = NSMenuItem(title: "Backend: \(STTBackend.current.displayName)", action: nil, keyEquivalent: "")
        backendLabel.isEnabled = false
        menu.addItem(backendLabel)

        menu.addItem(NSMenuItem.separator())

        if isPaused {
            menu.addItem(NSMenuItem(title: "Resume", action: #selector(resumeAction), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Pause", action: #selector(pauseAction), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        // Dictation Mode submenu
        let modeItem = NSMenuItem(title: "Dictation Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()

        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDictationMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (mode == dictationMode) ? .on : .off
            modeMenu.addItem(item)
        }

        modeMenu.addItem(NSMenuItem.separator())

        let shortcutTitle = "Configure Push-to-Talk Shortcut... (\(HotKeyPreferences.displayString(for: HotKeyPreferences.pushToTalkCombo)))"
        modeMenu.addItem(NSMenuItem(title: shortcutTitle, action: #selector(configurePushToTalkShortcut), keyEquivalent: ""))

        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(NSMenuItem.separator())

        addInputFocusLockMenuItems(to: menu)

        menu.addItem(NSMenuItem.separator())

        let enterItem = NSMenuItem(title: "Press Enter After Speech", action: #selector(toggleEnterAction), keyEquivalent: "")
        enterItem.state = pressEnterAfterSpeech ? .on : .off
        menu.addItem(enterItem)

        let webhookItem = NSMenuItem(title: "Send Final Utterances to Webhook", action: #selector(toggleWebhookOutput), keyEquivalent: "")
        webhookItem.state = webhookOutputEnabled ? .on : .off
        menu.addItem(webhookItem)

        let webhookURLItem = NSMenuItem(title: "Configure Webhook URL...", action: #selector(configureWebhookOutputURL), keyEquivalent: "")
        menu.addItem(webhookURLItem)

        if webhookOutputEnabled {
            let webhookStatusItem = NSMenuItem(title: "Webhook: \(lastWebhookStatus)", action: nil, keyEquivalent: "")
            webhookStatusItem.isEnabled = false
            menu.addItem(webhookStatusItem)
        }

        // Capture system audio (FaceTime, Zoom, browser, etc.) via ScreenCaptureKit
        let systemAudioItem = NSMenuItem(title: "Capture System Audio (Experimental)", action: #selector(toggleSystemAudioCapture), keyEquivalent: "")
        systemAudioItem.state = UserDefaults.standard.bool(forKey: "captureSystemAudio") ? .on : .off
        menu.addItem(systemAudioItem)

        // Only show dual-pass option for local backend
        if !STTBackend.current.returnsPunctuatedText {
            let refinementItem = NSMenuItem(title: "Dual-Pass Refinement (Punctuation)", action: #selector(toggleRefinementAction), keyEquivalent: "")
            refinementItem.state = enableDualPassRefinement ? .on : .off
            menu.addItem(refinementItem)
        }

        // Speaker Labels (Diarization) — Deepgram only
        if STTBackend.current == .deepgram {
            let labelsItem = NSMenuItem(title: "Speaker Labels (Diarization)", action: #selector(toggleSpeakerLabels), keyEquivalent: "")
            labelsItem.state = SpeakerLabelMap.enabled ? .on : .off
            menu.addItem(labelsItem)

            // Enrolled speakers submenu (hybrid override layer)
            let enrolledItem = NSMenuItem(title: "Enrolled Speakers (Hybrid)", action: nil, keyEquivalent: "")
            let enrolledMenu = NSMenu()
            let enrolledList = SpeakerRegistry.loadAll()
            if enrolledList.isEmpty {
                let placeholder = NSMenuItem(title: "(No enrolled speakers)", action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                enrolledMenu.addItem(placeholder)
            } else {
                for sp in enrolledList {
                    let item = NSMenuItem(title: "Remove '\(sp.name)'", action: #selector(removeEnrolledSpeaker(_:)), keyEquivalent: "")
                    item.representedObject = sp.id
                    enrolledMenu.addItem(item)
                }
            }
            enrolledMenu.addItem(NSMenuItem.separator())
            enrolledMenu.addItem(NSMenuItem(title: "Enroll New Speaker…", action: #selector(enrollNewSpeaker), keyEquivalent: ""))
            enrolledItem.submenu = enrolledMenu
            menu.addItem(enrolledItem)

            let nameItem = NSMenuItem(title: "Name Speakers", action: nil, keyEquivalent: "")
            let nameMenu = NSMenu()
            let seen = SpeakerLabelMap.seenSpeakerIds()
            if seen.isEmpty {
                let placeholder = NSMenuItem(title: "(No speakers seen yet)", action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                nameMenu.addItem(placeholder)
            } else {
                for id in seen {
                    let title = "Speaker \(id) → \(SpeakerLabelMap.name(forSpeakerId: id))"
                    let item = NSMenuItem(title: title, action: #selector(renameSpeaker(_:)), keyEquivalent: "")
                    item.representedObject = id
                    nameMenu.addItem(item)
                }
            }
            nameMenu.addItem(NSMenuItem.separator())
            nameMenu.addItem(NSMenuItem(title: "Reset All Names", action: #selector(resetSpeakerNames), keyEquivalent: ""))
            nameItem.submenu = nameMenu
            menu.addItem(nameItem)
        }

        menu.addItem(NSMenuItem.separator())

        // STT Backend submenu
        let backendItem = NSMenuItem(title: "STT Backend", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()

        for backend in STTBackend.allCases {
            let item = NSMenuItem(title: backend.displayName, action: #selector(selectBackend(_:)), keyEquivalent: "")
            item.representedObject = backend.rawValue
            item.state = (backend == STTBackend.current) ? .on : .off
            backendMenu.addItem(item)
        }

        backendMenu.addItem(NSMenuItem.separator())

        // API Key management
        let apiKeyItem = NSMenuItem(title: "Set Deepgram API Key...", action: #selector(setDeepgramAPIKey), keyEquivalent: "")
        let hasKey = APIKeyStore.get(for: .deepgram) != nil
        if hasKey {
            apiKeyItem.title = "Update Deepgram API Key..."
        }
        backendMenu.addItem(apiKeyItem)

        let openAIKeyItem = NSMenuItem(title: "Set OpenAI API Key...", action: #selector(setOpenAIAPIKey), keyEquivalent: "")
        let hasOpenAIKey = APIKeyStore.get(for: .openAIRealtime) != nil
        if hasOpenAIKey {
            openAIKeyItem.title = "Update OpenAI API Key..."
        }
        backendMenu.addItem(openAIKeyItem)

        backendItem.submenu = backendMenu
        menu.addItem(backendItem)

        menu.addItem(NSMenuItem.separator())

        // Indicator Style submenu
        let orbStyleItem = NSMenuItem(title: "Indicator Style", action: nil, keyEquivalent: "")
        let orbStyleMenu = NSMenu()

        let currentStyle = overlayWindow?.overlayViewModel.orbStyle ?? .voronoi

        for style in OverlayViewModel.OrbStyle.allCases {
            let styleItem = NSMenuItem(title: style.rawValue, action: #selector(selectOrbStyle(_:)), keyEquivalent: "")
            styleItem.representedObject = style
            styleItem.state = (style == currentStyle) ? .on : .off
            orbStyleMenu.addItem(styleItem)
        }

        orbStyleItem.submenu = orbStyleMenu
        menu.addItem(orbStyleItem)

        menu.addItem(NSMenuItem.separator())

        if overlayWindow?.isVisible == true {
            menu.addItem(NSMenuItem(title: "Hide Indicator", action: #selector(hideOverlayAction), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Show Indicator", action: #selector(showOverlayAction), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit Yappatron", action: #selector(quitAction), keyEquivalent: "q"))

        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil
    }

    func addInputFocusLockMenuItems(to menu: NSMenu) {
        let shortcut = HotKeyPreferences.displayString(for: HotKeyPreferences.inputFocusLockCombo)

        if let lockedInputFocusTarget {
            let statusItem = NSMenuItem(title: "Input Locked: \(lockedInputFocusTarget.displayName)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem(title: "Unlock Input Focus (\(shortcut))", action: #selector(toggleInputFocusLockAction), keyEquivalent: ""))
        } else {
            let targetName = recentInputFocusTarget?.displayName ?? "Current Field"
            menu.addItem(NSMenuItem(title: "Lock Input Focus to \(targetName) (\(shortcut))", action: #selector(toggleInputFocusLockAction), keyEquivalent: ""))
        }
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String

        switch engine.status {
        case .initializing, .downloadingModels:
            symbolName = "waveform.badge.ellipsis"
        case .ready, .listening:
            if isPaused {
                symbolName = "waveform.slash"
            } else if engine.isSpeaking {
                symbolName = "waveform.circle.fill"
            } else {
                symbolName = "waveform"
            }
        case .error:
            symbolName = "waveform.badge.exclamationmark"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Yappatron")
        image = image?.withSymbolConfiguration(config)
        button.image = image
        if let lockedInputFocusTarget {
            button.toolTip = "Yappatron - input locked to \(lockedInputFocusTarget.displayName)"
        } else {
            button.toolTip = "Yappatron"
        }
    }

    // MARK: - Overlay

    func setupOverlay() {
        overlayWindow = OverlayWindow()
        overlayWindow?.overlayViewModel.orbStyle = indicatorStyle
        overlayController = OverlayWindowController(window: overlayWindow!)

        focusLockWindow = FocusLockOverlayWindow()
        focusLockController = FocusLockOverlayWindowController(window: focusLockWindow!)
    }

    func toggleOverlay() {
        if overlayWindow?.isVisible == true {
            overlayWindow?.orderOut(nil)
        } else {
            showOverlay()
        }
    }

    func showOverlay() {
        overlayWindow?.orderFrontRegardless()
        overlayWindow?.positionAtBottom()
    }

    // MARK: - Hot Keys

    func setupHotKeys() {
        togglePauseHotKey = HotKey(key: .escape, modifiers: [.command])
        togglePauseHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in
                if self?.isPaused == true {
                    self?.resumeAction()
                } else {
                    self?.pauseAction()
                }
            }
        }

        toggleOverlayHotKey = HotKey(key: .space, modifiers: [.option])
        toggleOverlayHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in
                self?.toggleOverlay()
            }
        }

        registerInputFocusLockShortcut()

        registerPushToTalkHotKey()
    }

    func registerInputFocusLockShortcut() {
        unregisterInputFocusLockShortcut()

        let combo = HotKeyPreferences.inputFocusLockCombo

        toggleInputFocusLockHotKey = HotKey(keyCombo: combo)
        toggleInputFocusLockHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in
                self?.triggerInputFocusLockShortcut()
            }
        }

        inputFocusLockLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.eventMatchesInputFocusLockShortcut(event) == true {
                Task { @MainActor in
                    self?.triggerInputFocusLockShortcut()
                }
            }
            return event
        }

        inputFocusLockGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.eventMatchesInputFocusLockShortcut(event) == true else { return }
            Task { @MainActor in
                self?.triggerInputFocusLockShortcut()
            }
        }
    }

    func unregisterInputFocusLockShortcut() {
        toggleInputFocusLockHotKey = nil

        if let inputFocusLockLocalMonitor = inputFocusLockLocalMonitor {
            NSEvent.removeMonitor(inputFocusLockLocalMonitor)
            self.inputFocusLockLocalMonitor = nil
        }

        if let inputFocusLockGlobalMonitor = inputFocusLockGlobalMonitor {
            NSEvent.removeMonitor(inputFocusLockGlobalMonitor)
            self.inputFocusLockGlobalMonitor = nil
        }
    }

    func eventMatchesInputFocusLockShortcut(_ event: NSEvent) -> Bool {
        let combo = HotKeyPreferences.inputFocusLockCombo
        guard UInt32(event.keyCode) == combo.carbonKeyCode else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == combo.modifiers.intersection(.deviceIndependentFlagsMask)
    }

    func triggerInputFocusLockShortcut() {
        let now = Date()
        guard now.timeIntervalSince(lastInputFocusLockShortcutAt) > 0.25 else {
            return
        }

        lastInputFocusLockShortcutAt = now
        toggleInputFocusLockAction()
    }

    func registerPushToTalkHotKey() {
        unregisterPushToTalkInput()

        guard dictationMode == .pushToTalk else { return }

        let combo = HotKeyPreferences.pushToTalkCombo

        if HotKeyPreferences.isModifierOnly(combo) {
            registerPushToTalkModifierMonitor(combo: combo)
            return
        }

        pushToTalkHotKey = HotKey(keyCombo: combo)
        pushToTalkHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in
                self?.beginPushToTalkCapture()
            }
        }
        pushToTalkHotKey?.keyUpHandler = { [weak self] in
            Task { @MainActor in
                await self?.endPushToTalkCapture()
            }
        }
    }

    func unregisterPushToTalkInput() {
        pushToTalkHotKey = nil

        if let pushToTalkLocalMonitor = pushToTalkLocalMonitor {
            NSEvent.removeMonitor(pushToTalkLocalMonitor)
            self.pushToTalkLocalMonitor = nil
        }

        if let pushToTalkGlobalMonitor = pushToTalkGlobalMonitor {
            NSEvent.removeMonitor(pushToTalkGlobalMonitor)
            self.pushToTalkGlobalMonitor = nil
        }
    }

    func registerPushToTalkModifierMonitor(combo: KeyCombo) {
        pushToTalkLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handlePushToTalkModifierEvent(event, combo: combo)
            }
            return event
        }

        pushToTalkGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handlePushToTalkModifierEvent(event, combo: combo)
            }
        }
    }

    func handlePushToTalkModifierEvent(_ event: NSEvent, combo: KeyCombo) {
        guard dictationMode == .pushToTalk,
              let isPressed = HotKeyPreferences.modifierPressedState(for: event, combo: combo) else {
            return
        }

        if isPressed {
            beginPushToTalkCapture()
        } else {
            Task {
                await endPushToTalkCapture()
            }
        }
    }

    func applyDictationModeAfterEngineReady() {
        guard !isPaused else {
            updateOverlayStatus()
            updateStatusIcon()
            return
        }

        switch dictationMode {
        case .alwaysOn:
            engine.startCapture()
        case .pushToTalk:
            engine.stopCapture()
        }

        updateOverlayStatus()
        updateStatusIcon()
    }

    func beginPushToTalkCapture() {
        guard dictationMode == .pushToTalk, !isPaused, !isPushToTalkHeld else { return }

        isPushToTalkHeld = true
        engine.startCapture()
        updateOverlayStatus()
        updateStatusIcon()
        showOverlay()
    }

    func endPushToTalkCapture() async {
        guard dictationMode == .pushToTalk, isPushToTalkHeld else { return }

        isPushToTalkHeld = false
        engine.stopCapture()
        updateOverlayStatus()
        updateStatusIcon()

        try? await Task.sleep(nanoseconds: 120_000_000)
        await engine.finishCurrentUtterance()

        updateOverlayStatus()
        updateStatusIcon()
    }

    // MARK: - Actions

    @objc func pauseAction() {
        isPaused = true
        isPushToTalkHeld = false
        engine.stopCapture()
        Task {
            await engine.finishCurrentUtterance()
        }
        updateOverlayStatus()
        updateStatusIcon()
    }

    @objc func resumeAction() {
        isPaused = false
        applyDictationModeAfterEngineReady()
        updateStatusIcon()
    }

    @objc func toggleEnterAction() {
        pressEnterAfterSpeech.toggle()
    }

    @objc func toggleWebhookOutput() {
        webhookOutputEnabled.toggle()
        currentTypedText = ""
        lockedTextLength = 0
        lastWebhookStatus = webhookOutputEnabled ? "Enabled" : "Idle"
        updateStatusIcon()
    }

    @objc func configureWebhookOutputURL() {
        let alert = NSAlert()
        alert.messageText = "Webhook Output URL"
        alert.informativeText = "Final utterances will be POSTed as JSON to this URL."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
        input.stringValue = webhookOutputURL
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            webhookOutputURL = trimmed
            lastWebhookStatus = "URL saved"
            updateStatusIcon()
        }
    }

    @objc func toggleInputFocusLockAction() {
        if lockedInputFocusTarget != nil {
            unlockInputFocus()
        } else {
            lockCurrentFocusedInput()
        }
    }

    func lockCurrentFocusedInput() {
        let focusedTarget = InputSimulator.captureFocusedTextInputTarget()
        let target = focusedTarget?.isCurrentProcess == false ? focusedTarget : recentInputFocusTarget

        guard let target else {
            showInputFocusLockAlert(
                title: "No Text Input Focused",
                message: "Click into the text field Yappatron should type into, then press \(HotKeyPreferences.displayString(for: HotKeyPreferences.inputFocusLockCombo))."
            )
            return
        }

        lockedInputFocusTarget = target
        recentInputFocusTarget = target
        refreshFocusLockUI()
        updateStatusIcon()
        showOverlay()
        NSLog("[Yappatron] Input focus locked to \(target.displayName)")
    }

    func unlockInputFocus() {
        guard let target = lockedInputFocusTarget else { return }

        lockedInputFocusTarget = nil
        focusLockWindow?.orderOut(nil)
        updateStatusIcon()
        updateOverlayStatus()
        NSLog("[Yappatron] Input focus unlocked from \(target.displayName)")
    }

    @objc func toggleSystemAudioCapture() {
        let key = "captureSystemAudio"
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)

        let alert = NSAlert()
        alert.messageText = newValue ? "System Audio Capture Enabled (Experimental)" : "System Audio Capture Disabled"
        if newValue {
            alert.informativeText = """
            Yappatron will now mix the microphone with any audio playing on your Mac (FaceTime, Zoom, browser, etc.).

            Known limitations as of 2026-05-08:
            • FaceTime audio is not currently captured by ScreenCaptureKit on macOS, so this won't help with FaceTime calls.
            • Zoom captures both sides but transcription accuracy and diarization quality both degrade noticeably (echo and double-counted audio appear to be the cause).
            • Browser/YouTube playback works well.

            macOS will prompt for Screen Recording permission the first time this runs. Yappatron uses that permission only to capture audio — no screen contents are recorded.

            Quit and relaunch Yappatron for the change to take effect.
            """
        } else {
            alert.informativeText = "Yappatron will go back to capturing only the microphone. Quit and relaunch Yappatron for the change to take effect."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func toggleRefinementAction() {
        enableDualPassRefinement.toggle()

        // Inform user that they need to restart the app
        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "Please restart Yappatron for the dual-pass refinement change to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func toggleSpeakerLabels() {
        SpeakerLabelMap.enabled.toggle()
    }

    @objc func renameSpeaker(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        let alert = NSAlert()
        alert.messageText = "Name Speaker \(id)"
        alert.informativeText = "What should we label this speaker as in the typed transcript?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = SpeakerLabelMap.name(forSpeakerId: id)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SpeakerLabelMap.setName(input.stringValue, forSpeakerId: id)
        }
    }

    @objc func resetSpeakerNames() {
        SpeakerLabelMap.resetAll()
    }

    @objc func enrollNewSpeaker() {
        // Pause active transcription so the enrollment recorder owns the mic.
        let wasListening = engine.status == .listening
        if wasListening {
            engine.stopCapture()
        }

        let coordinator = EnrollSpeakerCoordinator()
        coordinator.enroll(suggestedName: "", embedder: engine.publicSpeakerEmbedder) { [weak self] result in
            DispatchQueue.main.async {
                let alert = NSAlert()
                switch result {
                case .success(let speaker):
                    alert.messageText = "Enrolled \(speaker.name)"
                    alert.informativeText = "Voiceprint saved. Future utterances matching this voice will be labeled [\(speaker.name)] regardless of Deepgram's speaker ID."
                    alert.alertStyle = .informational
                case .failure(let err):
                    alert.messageText = "Enrollment failed"
                    alert.informativeText = err.localizedDescription
                    alert.alertStyle = .warning
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()

                if wasListening {
                    self?.engine.startCapture()
                }
            }
        }
    }

    @objc func removeEnrolledSpeaker(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? SpeakerRegistry.remove(id: id)
    }

    @objc func selectDictationMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = DictationMode(rawValue: rawValue) else { return }

        switchDictationMode(to: mode)
    }

    private func switchDictationMode(to mode: DictationMode) {
        guard mode != dictationMode else { return }

        dictationMode = mode
        isPushToTalkHeld = false

        switch mode {
        case .alwaysOn:
            if !isPaused {
                engine.startCapture()
            }
        case .pushToTalk:
            engine.stopCapture()
            Task {
                await engine.finishCurrentUtterance()
            }
        }

        registerPushToTalkHotKey()
        updateOverlayStatus()
        updateStatusIcon()
    }

    @objc func configurePushToTalkShortcut() {
        let currentCombo = HotKeyPreferences.pushToTalkCombo
        guard let combo = ShortcutRecorderDialog.runModal(currentCombo: currentCombo) else { return }

        if let message = HotKeyPreferences.validationMessage(for: combo) {
            let alert = NSAlert()
            alert.messageText = "Shortcut Not Available"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        HotKeyPreferences.pushToTalkCombo = combo
        registerPushToTalkHotKey()
    }

    @objc func selectBackend(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let backend = STTBackend(rawValue: rawValue) else { return }

        guard backend != STTBackend.current else { return }

        // Check for API key if selecting cloud backend
        if backend.requiresAPIKey && APIKeyStore.get(for: backend) == nil {
            promptForAPIKey(backend: backend) { [weak self] success in
                if success {
                    self?.switchBackend(to: backend)
                }
            }
            return
        }

        switchBackend(to: backend)
    }

    private func switchBackend(to backend: STTBackend) {
        STTBackend.current = backend
        _ = UserDefaults.standard.synchronize()

        restartApplication(afterSwitchingTo: backend)
    }

    private func restartApplication(afterSwitchingTo backend: STTBackend) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")

        var environment = ProcessInfo.processInfo.environment
        let appURL = Bundle.main.bundleURL

        if appURL.pathExtension == "app" {
            environment["YAPPATRON_RELAUNCH_APP"] = appURL.path
            task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$YAPPATRON_RELAUNCH_APP\""]
        } else if let executableURL = Bundle.main.executableURL {
            environment["YAPPATRON_RELAUNCH_EXECUTABLE"] = executableURL.path
            task.arguments = ["-c", "sleep 0.6; \"$YAPPATRON_RELAUNCH_EXECUTABLE\" >/dev/null 2>&1 &"]
        } else {
            showManualRestartAlert(for: backend)
            return
        }

        task.environment = environment

        do {
            try task.run()
            prepareForExit()
            NSApp.terminate(nil)
        } catch {
            NSLog("[Yappatron] Failed to schedule relaunch: \(error.localizedDescription)")
            showManualRestartAlert(for: backend)
        }
    }

    private func showManualRestartAlert(for backend: STTBackend) {
        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "Switched to \(backend.rawValue), but Yappatron could not relaunch itself. Please quit and reopen Yappatron for the change to take effect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func setDeepgramAPIKey() {
        promptForAPIKey(backend: .deepgram, completion: nil)
    }

    @objc func setOpenAIAPIKey() {
        promptForAPIKey(backend: .openAIRealtime, completion: nil)
    }

    private func promptForAPIKey(backend: STTBackend, completion: ((Bool) -> Void)?) {
        let alert = NSAlert()
        alert.messageText = "Enter \(backend.rawValue) API Key"
        alert.informativeText = "Your API key is stored in app preferences."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputField.placeholderString = "Paste your API key here"

        // Pre-fill with existing key (masked)
        if let existingKey = APIKeyStore.get(for: backend) {
            inputField.stringValue = existingKey
        }

        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let key = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                APIKeyStore.save(key: key, for: backend)
                NSLog("[Yappatron] API key saved for \(backend.rawValue)")
                completion?(true)
            } else {
                completion?(false)
            }
        } else {
            completion?(false)
        }
    }

    @objc func selectOrbStyle(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? OverlayViewModel.OrbStyle {
            indicatorStyle = style
            overlayWindow?.overlayViewModel.orbStyle = style
            overlayWindow?.positionAtBottom()
        }
    }

    @objc func showOverlayAction() {
        showOverlay()
    }

    @objc func hideOverlayAction() {
        overlayWindow?.orderOut(nil)
    }

    @objc func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitAction() {
        prepareForExit()
        NSApp.terminate(nil)
    }

    private func prepareForExit() {
        focusObservationTimer?.invalidate()
        unregisterInputFocusLockShortcut()
        unregisterPushToTalkInput()
        webhookOutbox.cancelAll()
        engine.cleanup()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var pushToTalkShortcut = HotKeyPreferences.displayString(for: HotKeyPreferences.pushToTalkCombo)
    @AppStorage("webhookOutputEnabled") private var webhookOutputEnabled = false
    @AppStorage("webhookOutputURL") private var webhookOutputURL = ""

    var body: some View {
        Form {
            Section("About") {
                Text("Yappatron")
                    .font(.headline)
                Text("Voice dictation powered by Nemotron, Deepgram, and OpenAI Realtime")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                LabeledContent("Toggle Pause", value: "⌘ Escape")
                LabeledContent("Toggle Indicator", value: "⌥ Space")
                LabeledContent("Input Focus Lock", value: HotKeyPreferences.displayString(for: HotKeyPreferences.inputFocusLockCombo))
                LabeledContent("Push to Talk", value: pushToTalkShortcut)
                Button("Configure Push-to-Talk Shortcut...") {
                    let currentCombo = HotKeyPreferences.pushToTalkCombo
                    guard let combo = ShortcutRecorderDialog.runModal(currentCombo: currentCombo) else { return }
                    HotKeyPreferences.pushToTalkCombo = combo
                    pushToTalkShortcut = HotKeyPreferences.displayString(for: combo)
                }
            }

            Section("Dictation") {
                LabeledContent("Mode", value: DictationMode.current.title)
                LabeledContent("Indicator", value: UserDefaults.standard.string(forKey: "indicatorStyle") ?? OverlayViewModel.OrbStyle.voronoi.rawValue)
                Text("Change mode via the menu bar right-click menu")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("STT Backend") {
                LabeledContent("Current", value: STTBackend.current.displayName)
                Text("Change via the menu bar right-click menu")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Webhook Output") {
                Toggle("Send Final Utterances", isOn: $webhookOutputEnabled)
                TextField("URL", text: $webhookOutputURL)
                Text("Default: http://127.0.0.1:3002/input/yappatron")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 500)
    }
}
