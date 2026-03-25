import SwiftUI
import HotKey
import Combine

@main
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

    // Core
    var engine: TranscriptionEngine!
    var inputSimulator: InputSimulator!
    var batchProcessor: BatchProcessor?
    var refinementManager: TextRefinementManager?

    // Hotkeys
    var togglePauseHotKey: HotKey?
    var toggleOverlayHotKey: HotKey?

    // State
    @Published var isPaused = false
    @Published var currentTypedText = "" // What we've typed so far (for backspace corrections)
    var lockedTextLength = 0             // Characters confirmed by is_final (never backspace into these)

    // Settings
    var pressEnterAfterSpeech: Bool {
        get { UserDefaults.standard.bool(forKey: "pressEnterAfterSpeech") }
        set { UserDefaults.standard.set(newValue, forKey: "pressEnterAfterSpeech") }
    }

    var enableDualPassRefinement: Bool {
        get { UserDefaults.standard.bool(forKey: "enableDualPassRefinement") }
        set { UserDefaults.standard.set(newValue, forKey: "enableDualPassRefinement") }
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
            engine.startListening()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            engine.cleanup()
        }
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

        // Locked text advanced (cloud backends — update protected boundary)
        engine.onLockedTextAdvanced = { [weak self] lockedLen in
            Task { @MainActor in
                self?.lockedTextLength = lockedLen
            }
        }

        // Utterance complete callback - triggers batch refinement (if enabled, local backend only)
        if enableDualPassRefinement && !STTBackend.current.returnsPunctuatedText {
            engine.onUtteranceComplete = { [weak self] audioSamples, streamedText in
                Task { @MainActor in
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
                self?.overlayWindow?.overlayViewModel.status = .listening
                self?.overlayWindow?.overlayViewModel.isSpeaking = false
                self?.updateStatusIcon()

                // Auto-hide after a delay
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self?.overlayWindow?.overlayViewModel.isSpeaking == false {
                    self?.overlayWindow?.orderOut(nil)
                }
            }
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

    /// Handle partial transcription updates (streaming text)
    /// For cloud backends: only allows backspacing into interim (tentative) text, never into locked finals
    func handlePartialTranscription(_ partial: String) {
        guard !isPaused else { return }

        guard InputSimulator.isTextInputFocused() else {
            return
        }

        if STTBackend.current.returnsPunctuatedText {
            // Cloud backend: don't type during speech.
            // All typing happens in handleFinalTranscription (clean, all at once).
            // Partials still flow through for orb/speech detection.
            return
        }

        // Local backend: original behavior
        inputSimulator.applyTextUpdate(from: currentTypedText, to: partial)
        currentTypedText = partial
    }

    /// Handle final transcription (EOU detected)
    /// Behavior depends on dual-pass refinement setting and backend
    func handleFinalTranscription(_ text: String) {
        guard !isPaused else { return }

        // Check if input is focused
        guard InputSimulator.isTextInputFocused() else {
            NSLog("[Yappatron] No text input focused, ignoring transcription")
            return
        }

        // Correct any interim drift — finals are authoritative
        if currentTypedText != text {
            inputSimulator.applyTextUpdate(from: currentTypedText, to: text)
            currentTypedText = text
        }

        // Reset locked boundary
        lockedTextLength = 0

        // Cloud backends return punctuated text — no dual-pass needed
        // If dual-pass refinement is DISABLED, add spacing/enter immediately
        // If ENABLED (local only), wait for refinement to complete
        let needsRefinement = enableDualPassRefinement && !STTBackend.current.returnsPunctuatedText
        if !needsRefinement {
            // Add trailing space
            inputSimulator.typeString(" ")

            // Press enter if enabled
            if pressEnterAfterSpeech {
                inputSimulator.pressEnter()
            }

            // Reset for next utterance
            currentTypedText = ""
        }
        // If dual-pass enabled, spacing/enter will be added in handleRefinementComplete()
    }

    /// Called after batch refinement completes (dual-pass mode only)
    func handleRefinementComplete(_ refinedText: String) {
        // Update tracking to reflect refined text
        currentTypedText = refinedText

        // Add trailing space for next utterance
        inputSimulator.typeString(" ")

        // Press enter if enabled
        if pressEnterAfterSpeech {
            inputSimulator.pressEnter()
        }

        // Reset for next utterance
        currentTypedText = ""
    }

    func updateOverlayStatus() {
        switch engine.status {
        case .initializing:
            overlayWindow?.overlayViewModel.status = .initializing
        case .downloadingModels:
            overlayWindow?.overlayViewModel.status = .downloading(0.5) // Indeterminate
        case .ready:
            overlayWindow?.overlayViewModel.status = .listening
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
        case .ready, .listening: statusText = isPaused ? "⏸ Paused" : "🎙 Listening"
        case .error(let msg): statusText = "❌ \(msg)"
        }

        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Show current backend
        let backendLabel = NSMenuItem(title: "Backend: \(STTBackend.current.rawValue)", action: nil, keyEquivalent: "")
        backendLabel.isEnabled = false
        menu.addItem(backendLabel)

        menu.addItem(NSMenuItem.separator())

        if isPaused {
            menu.addItem(NSMenuItem(title: "Resume", action: #selector(resumeAction), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Pause", action: #selector(pauseAction), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        let enterItem = NSMenuItem(title: "Press Enter After Speech", action: #selector(toggleEnterAction), keyEquivalent: "")
        enterItem.state = pressEnterAfterSpeech ? .on : .off
        menu.addItem(enterItem)

        // Only show dual-pass option for local backend
        if !STTBackend.current.returnsPunctuatedText {
            let refinementItem = NSMenuItem(title: "Dual-Pass Refinement (Punctuation)", action: #selector(toggleRefinementAction), keyEquivalent: "")
            refinementItem.state = enableDualPassRefinement ? .on : .off
            menu.addItem(refinementItem)
        }

        menu.addItem(NSMenuItem.separator())

        // STT Backend submenu
        let backendItem = NSMenuItem(title: "STT Backend", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()

        for backend in STTBackend.allCases {
            let item = NSMenuItem(title: backend.rawValue, action: #selector(selectBackend(_:)), keyEquivalent: "")
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

        backendItem.submenu = backendMenu
        menu.addItem(backendItem)

        menu.addItem(NSMenuItem.separator())

        // Orb Style submenu
        let orbStyleItem = NSMenuItem(title: "Orb Style", action: nil, keyEquivalent: "")
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
    }

    // MARK: - Overlay

    func setupOverlay() {
        overlayWindow = OverlayWindow()
        overlayController = OverlayWindowController(window: overlayWindow!)
    }

    func toggleOverlay() {
        if overlayWindow?.isVisible == true {
            overlayWindow?.orderOut(nil)
        } else {
            showOverlay()
        }
    }

    func showOverlay() {
        overlayWindow?.makeKeyAndOrderFront(nil)
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
    }

    // MARK: - Actions

    @objc func pauseAction() {
        isPaused = true
        engine.stopListening()
        updateStatusIcon()
    }

    @objc func resumeAction() {
        isPaused = false
        engine.startListening()
        updateStatusIcon()
    }

    @objc func toggleEnterAction() {
        pressEnterAfterSpeech.toggle()
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

    @objc func selectBackend(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let backend = STTBackend(rawValue: rawValue) else { return }

        // Check for API key if selecting cloud backend
        if backend == .deepgram && APIKeyStore.get(for: .deepgram) == nil {
            promptForAPIKey(backend: .deepgram) { [weak self] success in
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

        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "Switched to \(backend.rawValue). Please restart Yappatron for the change to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func setDeepgramAPIKey() {
        promptForAPIKey(backend: .deepgram, completion: nil)
    }

    private func promptForAPIKey(backend: STTBackend, completion: ((Bool) -> Void)?) {
        let alert = NSAlert()
        alert.messageText = "Enter \(backend.rawValue) API Key"
        alert.informativeText = "Your API key is stored securely in the macOS Keychain."
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
            overlayWindow?.overlayViewModel.orbStyle = style
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
        engine.cleanup()
        NSApp.terminate(nil)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                Text("Yappatron")
                    .font(.headline)
                Text("Voice dictation powered by Parakeet TDT / Deepgram")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                LabeledContent("Toggle Pause", value: "⌘ Escape")
                LabeledContent("Toggle Indicator", value: "⌥ Space")
            }

            Section("STT Backend") {
                LabeledContent("Current", value: STTBackend.current.rawValue)
                Text("Change via the menu bar right-click menu")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 250)
    }
}
