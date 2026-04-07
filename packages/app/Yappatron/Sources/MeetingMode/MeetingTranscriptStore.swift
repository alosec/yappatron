import Foundation
import Combine

/// One labeled line of transcript: a speaker said some text at a moment in time.
struct MeetingTranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let speakerName: String
    let text: String
}

/// Append-only labeled transcript for a meeting session.
/// Holds entries in memory for the live UI and mirrors them to a JSON file
/// in Application Support so they survive a crash or unintended quit.
@MainActor
final class MeetingTranscriptStore: ObservableObject {

    @Published private(set) var entries: [MeetingTranscriptEntry] = []

    let sessionStartedAt: Date
    private let fileURL: URL

    init(startedAt: Date = Date()) {
        self.sessionStartedAt = startedAt
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("Yappatron", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: startedAt)
        self.fileURL = dir.appendingPathComponent("meeting-\(stamp).json")
    }

    func append(speakerName: String, text: String) {
        let entry = MeetingTranscriptEntry(
            timestamp: Date(),
            speakerName: speakerName,
            text: text
        )
        entries.append(entry)
        persist()
    }

    var fileLocation: URL { fileURL }

    private func persist() {
        // Reformat to a portable JSON envelope every write. Cheap; meetings
        // generate at most a few entries per minute.
        let payload = OnDisk(
            startedAt: sessionStartedAt,
            entries: entries.map { OnDiskEntry(timestamp: $0.timestamp, speakerName: $0.speakerName, text: $0.text) }
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Yappatron] MeetingTranscriptStore: failed to persist: \(error.localizedDescription)")
        }
    }

    private struct OnDisk: Codable {
        let startedAt: Date
        let entries: [OnDiskEntry]
    }

    private struct OnDiskEntry: Codable {
        let timestamp: Date
        let speakerName: String
        let text: String
    }
}
