import SwiftUI
import HotKey
import Darwin

@main
struct YappatronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // UI Components
    var statusItem: NSStatusItem!
    var overlayWindow: OverlayWindow?
    var overlayController: OverlayWindowController?
    
    // Core components
    var webSocketClient: WebSocketClient!
    var audioCapture: AudioCapture!
    var inputSimulator: InputSimulator!
    var engineManager: EngineManager!
    var settings: AppSettings!
    
    // Hotkeys
    var undoWordHotKey: HotKey?
    var undoAllHotKey: HotKey?
    var togglePauseHotKey: HotKey?
    var toggleOverlayHotKey: HotKey?
    
    // State
    @Published var isPaused = false
    @Published var isSpeaking = false
    
    // Text buffer - accumulates until sent to input
    var pendingText = ""
    var sentText = ""
    
    // Context monitoring
    var contextTimer: Timer?
    var wasInputFocused = false
    
    // Auto-hide timer
    var hideTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        settings = AppSettings.shared
        engineManager = EngineManager.shared
        inputSimulator = InputSimulator()
        audioCapture = AudioCapture()
        
        // Request accessibility permission if we don't have it (only prompts once per install)
        if !InputSimulator.hasAccessibilityPermission() {
            _ = InputSimulator.requestAccessibilityPermissionIfNeeded()
        }
        
        setupStatusItem()
        setupOverlay()
        setupWebSocket()
        setupAudioCapture()
        setupHotKeys()
        startContextMonitoring()
        
        // Check if engine is already running, if not start it
        if !isEngineRunning() {
            engineManager.start(model: settings.whisperModel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.webSocketClient.connect()
            }
        } else {
            webSocketClient.connect()
        }
        
        settings.onModelChanged = { [weak self] newModel in
            self?.engineManager.restart(model: newModel)
        }
    }
    
    func isEngineRunning() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9876).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return result == 0
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    func cleanup() {
        contextTimer?.invalidate()
        audioCapture.stop()
        webSocketClient.disconnect()
        engineManager.stop()
    }
    
    // MARK: - Context Monitoring
    
    func startContextMonitoring() {
        contextTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkContextAndStream()
        }
    }
    
    func checkContextAndStream() {
        let isInputFocused = InputSimulator.isTextInputFocused()
        
        // If user just focused an input and we have pending text, stream it
        if isInputFocused && !pendingText.isEmpty {
            streamPendingToInput()
        }
        
        wasInputFocused = isInputFocused
    }
    
    func streamPendingToInput() {
        guard !pendingText.isEmpty else { return }
        
        let textToSend = pendingText
        pendingText = ""
        sentText += textToSend
        
        // Type it out
        inputSimulator.typeText(textToSend)
        
        // Update overlay
        updateOverlay()
    }
    
    // MARK: - Status Bar
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yappatron")
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        updateStatusIcon()
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
        switch engineManager.status {
        case .stopped: statusText = "⏹ Stopped"
        case .starting: statusText = "⏳ Starting..."
        case .running: statusText = isPaused ? "⏸ Paused" : "🎙 Listening"
        case .error(let msg): statusText = "❌ \(msg)"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        if isPaused {
            menu.addItem(NSMenuItem(title: "Resume", action: #selector(resumeAction), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Pause", action: #selector(pauseAction), keyEquivalent: ""))
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let undoWordItem = NSMenuItem(title: "Undo Word", action: #selector(undoWordAction), keyEquivalent: "z")
        undoWordItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(undoWordItem)
        
        menu.addItem(NSMenuItem(title: "Undo All", action: #selector(undoAllAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear", action: #selector(clearAction), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        
        if overlayWindow?.isVisible == true {
            menu.addItem(NSMenuItem(title: "Hide Bubble", action: #selector(hideOverlayAction), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Show Bubble", action: #selector(showOverlayAction), keyEquivalent: ""))
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
        guard let button = statusItem.button else { return }
        
        let symbolName: String
        
        switch engineManager.status {
        case .stopped:
            symbolName = "waveform"
        case .starting:
            symbolName = "waveform.badge.ellipsis"
        case .running:
            if isPaused {
                symbolName = "waveform.slash"
            } else if isSpeaking {
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
        overlayController = OverlayWindowController(window: overlayWindow)
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
    
    func updateOverlay() {
        overlayWindow?.updateText(pending: pendingText, sent: sentText)
    }
    
    func scheduleHideOverlay() {
        guard settings.autoHideOverlay else { return }
        guard pendingText.isEmpty else { return } // Don't hide if there's pending text
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: settings.autoHideDelay, repeats: false) { [weak self] _ in
            if self?.isSpeaking == false && self?.pendingText.isEmpty == true {
                self?.overlayWindow?.orderOut(nil)
            }
        }
    }
    
    // MARK: - Audio Capture
    
    func setupAudioCapture() {
        audioCapture.onAudioChunk = { [weak self] samples in
            guard let self = self, !self.isPaused else { return }
            self.webSocketClient.sendAudioChunk(samples)
        }
        
        audioCapture.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .error(let msg):
                    NSLog("[Audio] Error: %@", msg)
                case .noPermission:
                    NSLog("[Audio] No microphone permission")
                default:
                    break
                }
                self?.updateStatusIcon()
            }
        }
    }
    
    // MARK: - WebSocket
    
    func setupWebSocket() {
        webSocketClient = WebSocketClient()
        
        webSocketClient.onText = { [weak self] text in
            self?.handleIncomingText(text)
        }
        
        webSocketClient.onSpeechStart = { [weak self] in
            DispatchQueue.main.async {
                self?.isSpeaking = true
                self?.overlayWindow?.overlayViewModel.isSpeaking = true
                self?.updateStatusIcon()
                
                if self?.settings.showOverlayOnSpeech == true {
                    self?.showOverlay()
                }
                
                self?.hideTimer?.invalidate()
            }
        }
        
        webSocketClient.onSpeechEnd = { [weak self] in
            DispatchQueue.main.async {
                self?.isSpeaking = false
                self?.overlayWindow?.overlayViewModel.isSpeaking = false
                self?.updateStatusIcon()
                self?.scheduleHideOverlay()
            }
        }
        
        webSocketClient.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.audioCapture.start()
            }
        }
        
        webSocketClient.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.audioCapture.stop()
            }
        }
    }
    
    func handleIncomingText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Add to pending buffer
            self.pendingText += text
            
            // Update overlay
            self.updateOverlay()
            
            // If input is focused right now, stream immediately
            if InputSimulator.isTextInputFocused() {
                self.streamPendingToInput()
            }
        }
    }
    
    // MARK: - Hot Keys
    
    func setupHotKeys() {
        undoWordHotKey = HotKey(key: .z, modifiers: [.command, .shift])
        undoWordHotKey?.keyDownHandler = { [weak self] in
            self?.undoWordAction()
        }
        
        undoAllHotKey = HotKey(key: .z, modifiers: [.command, .option, .shift])
        undoAllHotKey?.keyDownHandler = { [weak self] in
            self?.undoAllAction()
        }
        
        togglePauseHotKey = HotKey(key: .escape, modifiers: [.command])
        togglePauseHotKey?.keyDownHandler = { [weak self] in
            if self?.isPaused == true {
                self?.resumeAction()
            } else {
                self?.pauseAction()
            }
        }
        
        toggleOverlayHotKey = HotKey(key: .space, modifiers: [.option])
        toggleOverlayHotKey?.keyDownHandler = { [weak self] in
            self?.toggleOverlay()
        }
    }
    
    // MARK: - Actions
    
    @objc func pauseAction() {
        isPaused = true
        webSocketClient.sendPause()
        updateStatusIcon()
    }
    
    @objc func resumeAction() {
        isPaused = false
        webSocketClient.sendResume()
        updateStatusIcon()
    }
    
    @objc func undoWordAction() {
        // Undo from sent text
        guard !sentText.isEmpty else { return }
        
        var undone = ""
        
        // Remove trailing spaces
        while sentText.last == " " {
            let char = sentText.removeLast()
            undone = String(char) + undone
            inputSimulator.deleteChar()
        }
        
        // Remove word
        while !sentText.isEmpty && sentText.last != " " {
            let char = sentText.removeLast()
            undone = String(char) + undone
            inputSimulator.deleteChar()
        }
        
        // Put back in pending
        pendingText = undone + pendingText
        updateOverlay()
    }
    
    @objc func undoAllAction() {
        // Pull all sent text back
        guard !sentText.isEmpty else { return }
        
        for _ in sentText {
            inputSimulator.deleteChar()
        }
        
        pendingText = sentText + pendingText
        sentText = ""
        updateOverlay()
    }
    
    @objc func clearAction() {
        pendingText = ""
        sentText = ""
        updateOverlay()
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
        cleanup()
        NSApp.terminate(nil)
    }
}
