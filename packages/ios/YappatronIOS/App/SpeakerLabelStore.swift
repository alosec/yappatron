import Foundation

/// UserDefaults-backed map of Deepgram speaker IDs (0, 1, 2, ...) to user-facing
/// names, plus a tracker for which IDs have been observed in the current app
/// run. Mirrors the Mac app's `SpeakerLabelMap` minus voiceprint enrollment.
///
/// Tomorrow-Callie shape: user opens the app, hits record, both speakers say
/// something, the menu shows "Speaker 0" and "Speaker 1", user taps to rename
/// them "Alex" and "Callie", subsequent webhook posts carry the human names.
@MainActor
final class SpeakerLabelStore: ObservableObject {
    private enum Keys {
        static let map = "speakerLabels.map"
        static let seen = "speakerLabels.seenIds"
    }

    private let defaults = UserDefaults.standard
    @Published private(set) var seenIDs: [Int] = []

    init() {
        seenIDs = (defaults.array(forKey: Keys.seen) as? [Int] ?? []).sorted()
    }

    func name(for speakerID: Int) -> String {
        let map = loadMap()
        if let name = map[String(speakerID)], !name.isEmpty {
            return name
        }
        return "Speaker \(speakerID)"
    }

    func setName(_ name: String, for speakerID: Int) {
        var map = loadMap()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: String(speakerID))
        } else {
            map[String(speakerID)] = trimmed
        }
        defaults.set(map, forKey: Keys.map)
    }

    func recordSeen(_ speakerID: Int) {
        guard speakerID >= 0 else { return }
        var seen = Set(seenIDs)
        if seen.insert(speakerID).inserted {
            let sorted = Array(seen).sorted()
            defaults.set(sorted, forKey: Keys.seen)
            seenIDs = sorted
        }
    }

    func clearSeen() {
        defaults.removeObject(forKey: Keys.seen)
        seenIDs = []
    }

    func resetAll() {
        defaults.removeObject(forKey: Keys.map)
        defaults.removeObject(forKey: Keys.seen)
        seenIDs = []
    }

    private func loadMap() -> [String: String] {
        return defaults.dictionary(forKey: Keys.map) as? [String: String] ?? [:]
    }
}
