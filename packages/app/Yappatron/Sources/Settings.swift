import Foundation
import SwiftUI
import ServiceManagement

/// Whisper model sizes
enum WhisperModel: String, CaseIterable, Codable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case largeV3 = "large-v3"
    
    var displayName: String {
        switch self {
        case .tiny: return "Tiny (75MB) - Fastest, lower quality"
        case .base: return "Base (145MB) - Fast, okay quality"
        case .small: return "Small (488MB) - Balanced ⭐"
        case .medium: return "Medium (1.5GB) - Better quality"
        case .largeV3: return "Large V3 (3GB) - Best quality"
        }
    }
}

/// App settings stored in UserDefaults
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    @Published var whisperModel: WhisperModel {
        didSet {
            defaults.set(whisperModel.rawValue, forKey: "whisperModel")
            onModelChanged?(whisperModel)
        }
    }
    
    @Published var vadThreshold: Double {
        didSet {
            defaults.set(vadThreshold, forKey: "vadThreshold")
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin()
        }
    }
    
    @Published var showOverlayOnSpeech: Bool {
        didSet {
            defaults.set(showOverlayOnSpeech, forKey: "showOverlayOnSpeech")
        }
    }
    
    @Published var autoHideOverlay: Bool {
        didSet {
            defaults.set(autoHideOverlay, forKey: "autoHideOverlay")
        }
    }
    
    @Published var autoHideDelay: Double {
        didSet {
            defaults.set(autoHideDelay, forKey: "autoHideDelay")
        }
    }
    
    /// Callback when model changes (to restart engine)
    var onModelChanged: ((WhisperModel) -> Void)?
    
    private init() {
        // Load saved settings or use defaults
        let savedModel = defaults.string(forKey: "whisperModel") ?? "small"
        self.whisperModel = WhisperModel(rawValue: savedModel) ?? .small
        
        let savedVad = defaults.double(forKey: "vadThreshold")
        self.vadThreshold = savedVad > 0 ? savedVad : 0.5
        
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        
        self.showOverlayOnSpeech = defaults.object(forKey: "showOverlayOnSpeech") as? Bool ?? true
        self.autoHideOverlay = defaults.object(forKey: "autoHideOverlay") as? Bool ?? true
        
        let savedDelay = defaults.double(forKey: "autoHideDelay")
        self.autoHideDelay = savedDelay > 0 ? savedDelay : 3.0
    }
    
    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        }
    }
}

/// Settings view
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var showingRestartAlert = false
    
    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, showingRestartAlert: $showingRestartAlert)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            ModelSettingsView(settings: settings, showingRestartAlert: $showingRestartAlert)
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
            
            ShortcutsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
        .alert("Restart Required", isPresented: $showingRestartAlert) {
            Button("Restart Now") {
                restartApp()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The model change will take effect after restarting Yappatron.")
        }
    }
    
    private func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        
        NSApp.terminate(nil)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Binding var showingRestartAlert: Bool
    
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            
            Divider()
            
            Toggle("Show overlay when speaking", isOn: $settings.showOverlayOnSpeech)
            
            Toggle("Auto-hide overlay", isOn: $settings.autoHideOverlay)
            
            if settings.autoHideOverlay {
                HStack {
                    Text("Hide after")
                    Slider(value: $settings.autoHideDelay, in: 1...10, step: 0.5)
                    Text("\(settings.autoHideDelay, specifier: "%.1f")s")
                        .frame(width: 40)
                }
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Binding var showingRestartAlert: Bool
    @State private var previousModel: WhisperModel = .small
    
    var body: some View {
        Form {
            Picker("Whisper Model", selection: $settings.whisperModel) {
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .onChange(of: settings.whisperModel) { oldValue, newValue in
                if newValue != previousModel {
                    showingRestartAlert = true
                    previousModel = newValue
                }
            }
            .onAppear {
                previousModel = settings.whisperModel
            }
            
            Text("Larger models are more accurate but slower. 'Small' is recommended for most users.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            HStack {
                Text("VAD Sensitivity")
                Slider(value: $settings.vadThreshold, in: 0.3...0.8, step: 0.05)
                Text("\(settings.vadThreshold, specifier: "%.2f")")
                    .frame(width: 40)
            }
            
            Text("Higher = more sensitive to speech (may pick up background noise)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

struct ShortcutsView: View {
    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 12) {
                ShortcutRow(keys: "⌘ ⇧ Z", action: "Undo last word")
                ShortcutRow(keys: "⌘ ⌥ ⇧ Z", action: "Undo all")
                ShortcutRow(keys: "⌘ ⎋", action: "Toggle pause")
                ShortcutRow(keys: "⌥ Space", action: "Toggle overlay")
            }
            
            Divider()
            
            Text("Keyboard shortcuts are global and work in any app.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

struct ShortcutRow: View {
    let keys: String
    let action: String
    
    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
            
            Text(action)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("Yappatron")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Version 0.1.0")
                .foregroundColor(.secondary)
            
            Text("Always-on voice dictation.\nJust yap.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Link("GitHub", destination: URL(string: "https://github.com/example/yappatron")!)
                .font(.caption)
        }
        .padding()
    }
}
