import Foundation
import UIKit
import UniformTypeIdentifiers

private enum YappatronPasteboard {
    static let source = "com.yappatron.ios"
    static let metadataType = "com.yappatron.transcript.metadata"
    static let textTypes = [
        UTType.utf8PlainText.identifier,
        UTType.plainText.identifier
    ]

    struct Metadata: Codable {
        let source: String
        let updatedAt: TimeInterval
        let autoInsertOnKeyboardOpen: Bool
        let pressReturnAfterInsert: Bool

        init(
            source: String,
            updatedAt: TimeInterval,
            autoInsertOnKeyboardOpen: Bool,
            pressReturnAfterInsert: Bool
        ) {
            self.source = source
            self.updatedAt = updatedAt
            self.autoInsertOnKeyboardOpen = autoInsertOnKeyboardOpen
            self.pressReturnAfterInsert = pressReturnAfterInsert
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(String.self, forKey: .source)
            updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
            autoInsertOnKeyboardOpen = try container.decode(Bool.self, forKey: .autoInsertOnKeyboardOpen)
            pressReturnAfterInsert = try container.decodeIfPresent(Bool.self, forKey: .pressReturnAfterInsert) ?? false
        }
    }
}

struct SharedTranscript: Equatable {
    let text: String
    let updatedAt: TimeInterval
    let autoInsertOnKeyboardOpen: Bool
    let pressReturnAfterInsert: Bool
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

        if removePasteboard,
           let item = UIPasteboard.general.items.first,
           let metadata = Self.metadata(from: item),
           metadata.source == YappatronPasteboard.source {
            UIPasteboard.general.items = []
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
        guard let item = UIPasteboard.general.items.first,
              let metadata = Self.metadata(from: item),
              metadata.source == YappatronPasteboard.source else {
            return SharedTranscript(
                text: "",
                updatedAt: 0,
                autoInsertOnKeyboardOpen: false,
                pressReturnAfterInsert: false
            )
        }

        let text = YappatronPasteboard.textTypes
            .compactMap { item[$0] as? String }
            .first ?? ""

        return SharedTranscript(
            text: text,
            updatedAt: metadata.updatedAt,
            autoInsertOnKeyboardOpen: metadata.autoInsertOnKeyboardOpen,
            pressReturnAfterInsert: metadata.pressReturnAfterInsert
        )
    }

    private func refreshPasteboardMetadata() {
        let transcript = latestTranscript()
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        publishToPasteboard(text: transcript.text, updatedAt: transcript.updatedAt)
    }

    private func publishToPasteboard(text: String, updatedAt: TimeInterval) {
        let metadata = YappatronPasteboard.Metadata(
            source: YappatronPasteboard.source,
            updatedAt: updatedAt,
            autoInsertOnKeyboardOpen: autoInsertOnKeyboardOpen,
            pressReturnAfterInsert: pressReturnAfterInsert
        )

        var item: [String: Any] = YappatronPasteboard.textTypes.reduce(into: [:]) { result, textType in
            result[textType] = text
        }

        if let data = try? JSONEncoder().encode(metadata) {
            item[YappatronPasteboard.metadataType] = data
        }

        UIPasteboard.general.setItems(
            [item],
            options: [
                .localOnly: true,
                .expirationDate: Date(timeIntervalSinceNow: 8 * 60 * 60)
            ]
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
}
