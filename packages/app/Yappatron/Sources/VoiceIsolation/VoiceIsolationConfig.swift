import Foundation

/// User-tunable settings for voice isolation + meeting mode. Persisted in UserDefaults.
enum VoiceIsolationConfig {

    private static let enabledKey = "voiceIsolation.enabled"
    private static let thresholdKey = "voiceIsolation.threshold"
    private static let captureModeKey = "voiceIsolation.captureMode"

    /// Cosine-distance threshold above which a speech window is rejected as
    /// "not a known speaker". Lower = stricter. Higher = looser.
    static let defaultThreshold: Float = 0.7

    /// Master on/off for the gate. When false, the engine bypasses the gate
    /// entirely and behaves like the original undecorated provider.
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var threshold: Float {
        get {
            let v = UserDefaults.standard.float(forKey: thresholdKey)
            return v > 0 ? v : defaultThreshold
        }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }

    /// Capture-unknown mode. When true and the gate is enabled, unknown speakers
    /// are written to the registry as "Unknown N" with allowed=false. When false,
    /// unknown speakers are silently dropped (normal isolation behavior).
    /// Defaults to OFF — capture mode is an explicit "I'm setting up Yappatron
    /// for a new environment" action, not the default behavior.
    static var captureUnknownsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: captureModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: captureModeKey) }
    }
}
