import Foundation
import UIKit
import UniformTypeIdentifiers

private enum YappatronPasteboard {
    static let source = "com.yappatron.ios"
    static let chunkRole = "chunk"
    static let stateRole = "state"
    static let commandRole = "command"
    static let metadataType = "com.yappatron.transcript.metadata"
    static let maxQueuedItems = 24
    static let recordingStateStaleAfter: TimeInterval = 3
    static let textTypes = [
        UTType.utf8PlainText.identifier,
        UTType.plainText.identifier
    ]

    struct Metadata: Codable {
        let source: String
        let updatedAt: TimeInterval
        let autoInsertOnKeyboardOpen: Bool
        let pressReturnAfterInsert: Bool
        let role: String
        let command: String?

        init(
            source: String,
            updatedAt: TimeInterval,
            autoInsertOnKeyboardOpen: Bool,
            pressReturnAfterInsert: Bool,
            role: String = YappatronPasteboard.chunkRole,
            command: String? = nil
        ) {
            self.source = source
            self.updatedAt = updatedAt
            self.autoInsertOnKeyboardOpen = autoInsertOnKeyboardOpen
            self.pressReturnAfterInsert = pressReturnAfterInsert
            self.role = role
            self.command = command
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(String.self, forKey: .source)
            updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
            autoInsertOnKeyboardOpen = try container.decode(Bool.self, forKey: .autoInsertOnKeyboardOpen)
            pressReturnAfterInsert = try container.decodeIfPresent(Bool.self, forKey: .pressReturnAfterInsert) ?? false
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? YappatronPasteboard.chunkRole
            command = try container.decodeIfPresent(String.self, forKey: .command)
        }
    }
}

struct SharedTranscript: Equatable {
    let text: String
    let updatedAt: TimeInterval
    let autoInsertOnKeyboardOpen: Bool
    let pressReturnAfterInsert: Bool
}

struct SharedDictationState: Equatable {
    let isRecording: Bool
    let liveTranscript: String
    let updatedAt: TimeInterval
    let pressReturnAfterInsert: Bool
}

struct SharedKeyboardCommand: Equatable {
    let command: String
    let updatedAt: TimeInterval
}

final class SharedTranscriptStore {
    static let shared = SharedTranscriptStore()

    private enum Keys {
        static let latestTranscript = "latestTranscript"
        static let latestTranscriptUpdatedAt = "latestTranscriptUpdatedAt"
        static let autoInsertOnKeyboardOpen = "autoInsertOnKeyboardOpen"
        static let pressReturnAfterInsert = "pressReturnAfterInsert"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var autoInsertOnKeyboardOpen: Bool {
        get {
            defaults.bool(forKey: Keys.autoInsertOnKeyboardOpen)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoInsertOnKeyboardOpen)
            refreshPasteboardMetadata()
        }
    }

    var pressReturnAfterInsert: Bool {
        get {
            defaults.bool(forKey: Keys.pressReturnAfterInsert)
        }
        set {
            defaults.set(newValue, forKey: Keys.pressReturnAfterInsert)
            refreshPasteboardMetadata()
        }
    }

    func saveTranscript(_ text: String, updatedAt: Date = Date()) {
        defaults.set(text, forKey: Keys.latestTranscript)
        defaults.set(updatedAt.timeIntervalSince1970, forKey: Keys.latestTranscriptUpdatedAt)

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            publishToPasteboard(text: text, updatedAt: updatedAt.timeIntervalSince1970)
        }
    }

    func clearTranscript(removePasteboard: Bool) {
        defaults.set("", forKey: Keys.latestTranscript)
        defaults.set(0, forKey: Keys.latestTranscriptUpdatedAt)

        if removePasteboard {
            UIPasteboard.general.items = UIPasteboard.general.items.filter { item in
                Self.metadata(from: item)?.source != YappatronPasteboard.source
            }
        }
    }

    func latestTranscript() -> SharedTranscript {
        SharedTranscript(
            text: defaults.string(forKey: Keys.latestTranscript) ?? "",
            updatedAt: defaults.double(forKey: Keys.latestTranscriptUpdatedAt),
            autoInsertOnKeyboardOpen: autoInsertOnKeyboardOpen,
            pressReturnAfterInsert: pressReturnAfterInsert
        )
    }

    func latestTranscriptForKeyboard() -> SharedTranscript {
        keyboardTranscripts().last ?? SharedTranscript(
            text: "",
            updatedAt: 0,
            autoInsertOnKeyboardOpen: false,
            pressReturnAfterInsert: false
        )
    }

    func keyboardTranscripts(after updatedAt: TimeInterval = 0) -> [SharedTranscript] {
        UIPasteboard.general.items
            .compactMap { Self.transcript(from: $0, role: YappatronPasteboard.chunkRole) }
            .filter { $0.updatedAt > updatedAt }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    func saveDictationState(isRecording: Bool, liveTranscript: String, updatedAt: Date = Date()) {
        var items = yappatronItems(excludingRoles: [YappatronPasteboard.stateRole])
        items.append(makePasteboardItem(
            text: liveTranscript,
            updatedAt: updatedAt.timeIntervalSince1970,
            role: YappatronPasteboard.stateRole,
            command: isRecording ? "recording" : "idle"
        ))
        setYappatronItems(items)
    }

    func latestDictationStateForKeyboard() -> SharedDictationState {
        guard let item = latestItem(role: YappatronPasteboard.stateRole),
              let metadata = Self.metadata(from: item) else {
            return SharedDictationState(
                isRecording: false,
                liveTranscript: "",
                updatedAt: 0,
                pressReturnAfterInsert: pressReturnAfterInsert
            )
        }

        let text = Self.text(from: item)
        let recordingStateIsFresh = Date().timeIntervalSince1970 - metadata.updatedAt <= YappatronPasteboard.recordingStateStaleAfter
        return SharedDictationState(
            isRecording: metadata.command == "recording" && recordingStateIsFresh,
            liveTranscript: text,
            updatedAt: metadata.updatedAt,
            pressReturnAfterInsert: metadata.pressReturnAfterInsert
        )
    }

    func saveKeyboardCommand(_ command: String, updatedAt: Date = Date()) {
        var items = yappatronItems(excludingRoles: [YappatronPasteboard.commandRole])
        items.append(makePasteboardItem(
            text: command,
            updatedAt: updatedAt.timeIntervalSince1970,
            role: YappatronPasteboard.commandRole,
            command: command
        ))
        setYappatronItems(items)
    }

    func latestKeyboardCommand(after updatedAt: TimeInterval) -> SharedKeyboardCommand? {
        guard let item = latestItem(role: YappatronPasteboard.commandRole),
              let metadata = Self.metadata(from: item),
              let command = metadata.command,
              metadata.updatedAt > updatedAt else {
            return nil
        }

        return SharedKeyboardCommand(command: command, updatedAt: metadata.updatedAt)
    }

    private func refreshPasteboardMetadata() {
        let queuedItems = UIPasteboard.general.items
            .compactMap { Self.transcript(from: $0, role: YappatronPasteboard.chunkRole) }
            .map { makePasteboardItem(text: $0.text, updatedAt: $0.updatedAt, role: YappatronPasteboard.chunkRole) }
        let nonChunkItems = yappatronItems(excludingRoles: [YappatronPasteboard.chunkRole])

        if !queuedItems.isEmpty {
            setYappatronItems(nonChunkItems + queuedItems)
            return
        }

        let transcript = latestTranscript()
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        publishToPasteboard(text: transcript.text, updatedAt: transcript.updatedAt)
    }

    private func publishToPasteboard(text: String, updatedAt: TimeInterval) {
        var items = yappatronItems(excludingRoles: [])
        items = items.filter { item in
            guard let metadata = Self.metadata(from: item),
                  metadata.source == YappatronPasteboard.source,
                  metadata.role == YappatronPasteboard.chunkRole else {
                return false
            }

            return metadata.updatedAt != updatedAt
        }

        let nonChunkItems = yappatronItems(excludingRoles: [YappatronPasteboard.chunkRole])
        items.append(makePasteboardItem(text: text, updatedAt: updatedAt, role: YappatronPasteboard.chunkRole))
        if items.count > YappatronPasteboard.maxQueuedItems {
            items = Array(items.suffix(YappatronPasteboard.maxQueuedItems))
        }

        setYappatronItems(nonChunkItems + items)
    }

    private func makePasteboardItem(
        text: String,
        updatedAt: TimeInterval,
        role: String,
        command: String? = nil
    ) -> [String: Any] {
        let metadata = YappatronPasteboard.Metadata(
            source: YappatronPasteboard.source,
            updatedAt: updatedAt,
            autoInsertOnKeyboardOpen: autoInsertOnKeyboardOpen,
            pressReturnAfterInsert: pressReturnAfterInsert,
            role: role,
            command: command ?? (role == YappatronPasteboard.stateRole ? "idle" : nil)
        )

        var item: [String: Any] = YappatronPasteboard.textTypes.reduce(into: [:]) { result, textType in
            result[textType] = text
        }

        if let data = try? JSONEncoder().encode(metadata) {
            item[YappatronPasteboard.metadataType] = data
        }

        return item
    }

    private func setYappatronItems(_ items: [[String: Any]]) {
        UIPasteboard.general.setItems(
            items,
            options: [
                .localOnly: true,
                .expirationDate: Date(timeIntervalSinceNow: 8 * 60 * 60)
            ]
        )
    }

    private func yappatronItems(excludingRoles excludedRoles: Set<String>) -> [[String: Any]] {
        UIPasteboard.general.items.filter { item in
            guard let metadata = Self.metadata(from: item),
                  metadata.source == YappatronPasteboard.source else {
                return false
            }

            return !excludedRoles.contains(metadata.role)
        }
    }

    private func latestItem(role: String) -> [String: Any]? {
        UIPasteboard.general.items
            .filter { item in
                guard let metadata = Self.metadata(from: item),
                      metadata.source == YappatronPasteboard.source else {
                    return false
                }

                return metadata.role == role
            }
            .sorted { lhs, rhs in
                (Self.metadata(from: lhs)?.updatedAt ?? 0) < (Self.metadata(from: rhs)?.updatedAt ?? 0)
            }
            .last
    }

    private static func transcript(from item: [String: Any], role: String) -> SharedTranscript? {
        guard let metadata = Self.metadata(from: item),
              metadata.source == YappatronPasteboard.source,
              metadata.role == role else {
            return nil
        }

        return SharedTranscript(
            text: Self.text(from: item),
            updatedAt: metadata.updatedAt,
            autoInsertOnKeyboardOpen: metadata.autoInsertOnKeyboardOpen,
            pressReturnAfterInsert: metadata.pressReturnAfterInsert
        )
    }

    private static func metadata(from item: [String: Any]) -> YappatronPasteboard.Metadata? {
        if let data = item[YappatronPasteboard.metadataType] as? Data {
            return try? JSONDecoder().decode(YappatronPasteboard.Metadata.self, from: data)
        }

        if let string = item[YappatronPasteboard.metadataType] as? String,
           let data = string.data(using: .utf8) {
            return try? JSONDecoder().decode(YappatronPasteboard.Metadata.self, from: data)
        }

        return nil
    }

    private static func text(from item: [String: Any]) -> String {
        YappatronPasteboard.textTypes
            .compactMap { item[$0] as? String }
            .first ?? ""
    }
}
