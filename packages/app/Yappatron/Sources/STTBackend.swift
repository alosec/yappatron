import Foundation
import Security

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

// MARK: - Keychain API Key Storage

enum APIKeyStore {
    private static let service = "com.yappatron.api-keys"

    static func save(key: String, for backend: STTBackend) {
        let account = backend.rawValue
        let data = key.data(using: .utf8)!

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func get(for backend: STTBackend) -> String? {
        let account = backend.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for backend: STTBackend) {
        let account = backend.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
