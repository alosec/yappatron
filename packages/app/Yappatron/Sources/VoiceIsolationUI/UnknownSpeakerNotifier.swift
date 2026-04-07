import Foundation
import UserNotifications

/// Posts macOS notifications when the gate captures a new unknown speaker.
/// Falls back silently if the user hasn't granted notification permission.
@MainActor
final class UnknownSpeakerNotifier {

    private var permissionRequested = false

    /// Request permission to post notifications. Idempotent. Call once when
    /// the user first toggles capture mode on.
    func requestPermissionIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("[Yappatron] Notification permission error: \(error.localizedDescription)")
            } else {
                NSLog("[Yappatron] Notification permission: \(granted)")
            }
        }
    }

    func notifyCaptured(_ speaker: RegisteredSpeaker) {
        let content = UNMutableNotificationContent()
        content.title = "New voice captured"
        content.body = "Saved as \(speaker.name). Open Manage Speakers to name and allow them."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "yappatron.captured.\(speaker.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[Yappatron] Notification post failed: \(error.localizedDescription)")
            }
        }
    }
}
