import Foundation

/// Manual mapping from Deepgram speaker IDs (0, 1, 2, ...) to user-facing names.
/// Persisted in UserDefaults so names survive across sessions.
/// How to break between speaker turns in the typed text.
enum LineBreakStyle: String, CaseIterable {
    /// No break — speaker runs flow inline (today's default).
    case none
    /// Plain newline between turns. Works in TextEdit, Notes, most text fields.
    case newline
    /// Backslash + newline between turns. For terminals like Claude Code where
    /// `\<Enter>` produces a soft line break in the prompt buffer.
    case claudeCode

    var displayName: String {
        switch self {
        case .none: return "None (inline)"
        case .newline: return "Newline"
        case .claudeCode: return "Backslash + Newline (Claude Code)"
        }
    }

    /// The string inserted before a `[Name] ` label when the speaker changes
    /// from the previous run.
    var separator: String {
        switch self {
        case .none: return " "
        case .newline: return "\n"
        case .claudeCode: return "\\\n"
        }
    }
}

enum SpeakerLabelMap {

    private static let enabledKey = "speakerLabels.enabled"
    private static let mapKey = "speakerLabels.map"
    private static let seenIdsKey = "speakerLabels.seenIds"
    private static let lineBreakStyleKey = "speakerLabels.lineBreakStyle"

    static var lineBreakStyle: LineBreakStyle {
        get {
            let raw = UserDefaults.standard.string(forKey: lineBreakStyleKey) ?? ""
            return LineBreakStyle(rawValue: raw) ?? .none
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lineBreakStyleKey) }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func name(forSpeakerId id: Int) -> String {
        let map = loadMap()
        if let name = map[String(id)], !name.isEmpty {
            return name
        }
        return "Speaker \(id)"
    }

    static func setName(_ name: String, forSpeakerId id: Int) {
        var map = loadMap()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: String(id))
        } else {
            map[String(id)] = trimmed
        }
        UserDefaults.standard.set(map, forKey: mapKey)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: mapKey)
        UserDefaults.standard.removeObject(forKey: seenIdsKey)
    }

    /// IDs that have been observed during the current app run. Used to populate
    /// the "Name Speakers…" submenu so the user only sees speakers actually present.
    static func recordSeen(_ id: Int) {
        var seen = Set(loadSeen())
        if seen.insert(id).inserted {
            UserDefaults.standard.set(Array(seen).sorted(), forKey: seenIdsKey)
        }
    }

    static func seenSpeakerIds() -> [Int] {
        return loadSeen().sorted()
    }

    static func clearSeen() {
        UserDefaults.standard.removeObject(forKey: seenIdsKey)
    }

    private static func loadMap() -> [String: String] {
        return UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:]
    }

    private static func loadSeen() -> [Int] {
        return UserDefaults.standard.array(forKey: seenIdsKey) as? [Int] ?? []
    }
}
