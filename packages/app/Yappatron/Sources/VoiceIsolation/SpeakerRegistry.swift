import Foundation

/// One enrolled speaker. The same shape covers both deliberately enrolled users
/// (someone who walked through the script) and on-the-fly captures (an unknown
/// voice the system noticed during capture mode).
struct RegisteredSpeaker: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case enrolled        // user explicitly added via "Add Speaker…"
        case autoCaptured    // gate caught an unknown voice in capture mode
    }

    let id: String                      // stable UUID
    var name: String                    // user-facing label, editable
    var embedding: [Float]               // 256-dim L2-normalized
    var allowed: Bool                   // true → forward to STT (isolation) / label (meeting)
    var source: Source
    let createdAt: Date
    var updatedAt: Date
}

/// File-backed list of registered speakers. Single source of truth for both
/// isolation mode and meeting mode.
///
/// Thread model: this is a value-type wrapper around disk + an in-memory copy.
/// All mutations go through the static API, which re-saves the JSON file atomically.
/// Callers that need to react to changes should re-load after their own mutations.
enum SpeakerRegistry {

    private static let filename = "speakers.json"
    private static let legacyVoiceprintFilename = "voiceprint.json"

    // MARK: Persistence layout

    private struct OnDisk: Codable {
        var version: Int
        var speakers: [RegisteredSpeaker]
    }

    private static let currentVersion = 1

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Yappatron", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    private static var legacyVoiceprintURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Yappatron", isDirectory: true)
            .appendingPathComponent(legacyVoiceprintFilename)
    }

    // MARK: Read

    /// Load all speakers, performing one-time migration from the old single-voiceprint
    /// file if needed. Always returns a (possibly empty) list — never throws on missing file.
    static func loadAll() -> [RegisteredSpeaker] {
        migrateLegacyVoiceprintIfNeeded()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(OnDisk.self, from: data) else {
            return []
        }
        return decoded.speakers
    }

    static var hasAnySpeaker: Bool {
        !loadAll().isEmpty
    }

    static var hasAnyAllowedSpeaker: Bool {
        loadAll().contains { $0.allowed }
    }

    // MARK: Write

    static func saveAll(_ speakers: [RegisteredSpeaker]) throws {
        let payload = OnDisk(version: currentVersion, speakers: speakers)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Insert a new speaker, or replace an existing one with the same ID.
    static func upsert(_ speaker: RegisteredSpeaker) throws {
        var current = loadAll()
        if let idx = current.firstIndex(where: { $0.id == speaker.id }) {
            var updated = speaker
            updated.updatedAt = Date()
            current[idx] = updated
        } else {
            current.append(speaker)
        }
        try saveAll(current)
    }

    static func remove(id: String) throws {
        var current = loadAll()
        current.removeAll { $0.id == id }
        try saveAll(current)
    }

    static func setName(id: String, name: String) throws {
        var current = loadAll()
        guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
        current[idx].name = name
        current[idx].updatedAt = Date()
        try saveAll(current)
    }

    static func setAllowed(id: String, allowed: Bool) throws {
        var current = loadAll()
        guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
        current[idx].allowed = allowed
        current[idx].updatedAt = Date()
        try saveAll(current)
    }

    /// Pick the next "Unknown N" name that doesn't collide with an existing one.
    static func nextUnknownName() -> String {
        let existing = Set(loadAll().map { $0.name })
        var n = 1
        while existing.contains("Unknown \(n)") { n += 1 }
        return "Unknown \(n)"
    }

    // MARK: Migration

    private static func migrateLegacyVoiceprintIfNeeded() {
        let legacyURL = legacyVoiceprintURL
        let registryURL = fileURL
        let fm = FileManager.default

        // If a registry already exists, do nothing — even if a stale legacy file
        // is sitting there, the registry wins.
        if fm.fileExists(atPath: registryURL.path) {
            // Clean up the legacy file if both exist.
            if fm.fileExists(atPath: legacyURL.path) {
                try? fm.removeItem(at: legacyURL)
            }
            return
        }

        guard fm.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(LegacyVoiceprint.self, from: data) else {
            return
        }

        let migrated = RegisteredSpeaker(
            id: legacy.id,
            name: legacy.name,
            embedding: legacy.embedding,
            allowed: true,
            source: .enrolled,
            createdAt: legacy.createdAt,
            updatedAt: legacy.updatedAt
        )

        do {
            try saveAll([migrated])
            try? fm.removeItem(at: legacyURL)
            NSLog("[Yappatron] Migrated legacy voiceprint.json → speakers.json (1 speaker)")
        } catch {
            NSLog("[Yappatron] Legacy voiceprint migration failed: \(error.localizedDescription)")
        }
    }

    /// Mirror of the old StoredVoiceprint format, kept here only for migration.
    private struct LegacyVoiceprint: Codable {
        let id: String
        let name: String
        let embedding: [Float]
        let durationSeconds: Float
        let createdAt: Date
        let updatedAt: Date
    }
}
