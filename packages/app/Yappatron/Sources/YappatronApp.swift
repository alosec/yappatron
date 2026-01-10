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

    // Hotkeys
    var togglePauseHotKey: HotKey?
    var toggleOverlayHotKey: HotKey?
    
    // State
    @Published var isPaused = false
    @Published var currentTypedText = "" // What we've typed so far (for backspace corrections)
    
    // Settings
    var pressEnterAfterSpeech: Bool {
        get { UserDefaults.standard.bool(forKey: "pressEnterAfterSpeech") }
        set { UserDefaults.standard.set(newValue, forKey: "pressEnterAfterSpeech") }
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
        engine = TranscriptionEngine()

        // Request accessibility
        if !InputSimulator.hasAccessibilityPermission() {
            _ = InputSimulator.requestAccessibilityPermissionIfNeeded()
        }

        setupStatusItem()
        setupOverlay()
        setupHotKeys()
        setupEngineCallbacks()
        observeEngineStatus()

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
    /// Types text immediately (no refinement during streaming)
    func handlePartialTranscription(_ partial: String) {
        guard !isPaused else { return }

        // Check if input is focused
        guard InputSimulator.isTextInputFocused() else {
            return
        }

        // Type streaming text immediately
        inputSimulator.applyTextUpdate(from: currentTypedText, to: partial)
        currentTypedText = partial
    }

    /// Handle final transcription (EOU detected)
    /// Pure streaming - just add spacing and optionally press Enter
    func handleFinalTranscription(_ text: String) {
        guard !isPaused else { return }

        // Check if input is focused
        guard InputSimulator.isTextInputFocused() else {
            NSLog("[Yappatron] No text input focused, ignoring transcription")
            return
        }

        // Ensure final text is correct (in case partials diverged)
        if currentTypedText != text {
            inputSimulator.applyTextUpdate(from: currentTypedText, to: text)
            currentTypedText = text
        }

        // Add trailing space
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
                Text("Voice dictation powered by Parakeet TDT")
                    .foregroundStyle(.secondary)
            }
            
            Section("Shortcuts") {
                LabeledContent("Toggle Pause", value: "⌘ Escape")
                LabeledContent("Toggle Indicator", value: "⌥ Space")
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 200)
    }
}
