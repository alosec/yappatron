import Foundation

/// Available speech-to-text backends
enum STTBackend: String, CaseIterable {
    case local = "Local (Parakeet)"
    case deepgram = "Deepgram"
    case openAIRealtime = "OpenAI Realtime"

    /// User-facing display name. Kept separate from `rawValue` because
    /// `rawValue` is the persisted UserDefaults value and must stay stable
    /// across model swaps.
    var displayName: String {
        switch self {
        case .local: return "Local (Nemotron)"
        case .deepgram: return "Deepgram"
        case .openAIRealtime: return "OpenAI Realtime"
        }
    }

    /// UserDefaults key
    static let defaultsKey = "sttBackend"

    static var supportsLocalBackend: Bool {
        #if YAPPATRON_ENABLE_FLUIDAUDIO
        true
        #else
        false
        #endif
    }

    static var availableCases: [STTBackend] {
        allCases.filter(\.isAvailable)
    }

    static var defaultBackend: STTBackend {
        supportsLocalBackend ? .local : .openAIRealtime
    }

    /// Get the currently selected backend
    static var current: STTBackend {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultBackend.rawValue
            guard let backend = STTBackend(rawValue: raw), backend.isAvailable else {
                return defaultBackend
            }
            return backend
        }
        set {
            guard newValue.isAvailable else {
                UserDefaults.standard.set(defaultBackend.rawValue, forKey: defaultsKey)
                return
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var isAvailable: Bool {
        switch self {
        case .local:
            return STTBackend.supportsLocalBackend
        case .deepgram, .openAIRealtime:
            return true
        }
    }

    /// Whether this backend returns punctuated text (no need for dual-pass)
    var returnsPunctuatedText: Bool {
        switch self {
        case .local: return false
        case .deepgram, .openAIRealtime: return true
        }
    }

    /// Whether this backend needs a user-provided cloud API key
    var requiresAPIKey: Bool {
        switch self {
        case .local: return false
        case .deepgram, .openAIRealtime: return true
        }
    }
}

// MARK: - API Key Storage (UserDefaults)

enum APIKeyStore {
    private static let prefix = "apiKey_"

    static func save(key: String, for backend: STTBackend) {
        UserDefaults.standard.set(key, forKey: prefix + backend.rawValue)
    }

    static func get(for backend: STTBackend) -> String? {
        UserDefaults.standard.string(forKey: prefix + backend.rawValue)
    }

    static func delete(for backend: STTBackend) {
        UserDefaults.standard.removeObject(forKey: prefix + backend.rawValue)
    }
}
