import Foundation

/// Available speech-to-text backends
enum STTBackend: String, CaseIterable {
    case local = "Local (Parakeet)"
    case deepgram = "Deepgram"

    /// UserDefaults key
    static let defaultsKey = "sttBackend"

    /// Get the currently selected backend
    static var current: STTBackend {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? "local"
            return STTBackend(rawValue: raw) ?? .local
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// Whether this backend returns punctuated text (no need for dual-pass)
    var returnsPunctuatedText: Bool {
        switch self {
        case .local: return false
        case .deepgram: return true
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
