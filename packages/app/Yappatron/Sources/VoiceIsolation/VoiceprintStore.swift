import Foundation

/// Persisted voiceprint for the enrolled user.
/// A 256-dim L2-normalized embedding extracted by FluidAudio's diarizer.
struct StoredVoiceprint: Codable {
    let id: String
    let name: String
    let embedding: [Float]
    let durationSeconds: Float
    let createdAt: Date
    let updatedAt: Date
}

/// Loads/saves the user's voiceprint to Application Support.
/// Single-user model: there is exactly one enrolled voiceprint, or none.
enum VoiceprintStore {

    private static let filename = "voiceprint.json"

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Yappatron", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static var hasEnrolledVoiceprint: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func load() -> StoredVoiceprint? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredVoiceprint.self, from: data)
    }

    static func save(_ voiceprint: StoredVoiceprint) throws {
        let data = try JSONEncoder().encode(voiceprint)
        try data.write(to: fileURL, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
