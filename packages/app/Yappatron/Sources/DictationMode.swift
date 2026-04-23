import Foundation

enum DictationMode: String, CaseIterable {
    case alwaysOn
    case pushToTalk

    static let defaultsKey = "dictationMode"

    static var current: DictationMode {
        get {
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? DictationMode.alwaysOn.rawValue
            return DictationMode(rawValue: rawValue) ?? .alwaysOn
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .alwaysOn: return "Always On"
        case .pushToTalk: return "Push to Talk"
        }
    }

    var statusTitle: String {
        switch self {
        case .alwaysOn: return "Listening"
        case .pushToTalk: return "Push-to-Talk Idle"
        }
    }
}
