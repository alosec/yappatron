import Foundation

/// User-tunable settings for voice isolation. Persisted in UserDefaults.
enum VoiceIsolationConfig {

    private static let enabledKey = "voiceIsolation.enabled"
    private static let thresholdKey = "voiceIsolation.threshold"

    /// Cosine-distance threshold above which a speech window is rejected as "not the user".
    /// Lower = stricter (more false rejects of the user). Higher = looser (more leak-through).
    /// Starting default 0.7 — slightly looser than FluidAudio's 0.65 to bias against false rejects.
    static let defaultThreshold: Float = 0.7

    static var enabled: Bool {
        get {
            // Default ON once the user has enrolled. The gate itself checks for an enrolled
            // voiceprint, so this only takes effect when both flags align.
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
}
