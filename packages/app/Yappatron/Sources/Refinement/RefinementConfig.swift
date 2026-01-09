import Foundation

/// Configuration for continuous refinement
struct RefinementConfig {

    /// Enable/disable continuous refinement
    var isEnabled: Bool

    /// Minimum interval between refinements (throttling)
    var throttleInterval: TimeInterval

    /// Only refine for specific apps
    var enabledApps: Set<String>

    /// Fallback to simple approach if commands fail
    var fallbackOnError: Bool

    static let `default` = RefinementConfig(
        isEnabled: true,
        throttleInterval: 0.5,  // 500ms throttle
        enabledApps: ["Code", "Visual Studio Code", "TextEdit", "Notes"],
        fallbackOnError: true
    )

    /// Check if refinement should run for current app
    func shouldRefineForApp(_ appName: String?) -> Bool {
        guard isEnabled else { return false }
        guard let app = appName else { return false }

        // If empty, allow all apps
        if enabledApps.isEmpty { return true }

        return enabledApps.contains(app)
    }
}
