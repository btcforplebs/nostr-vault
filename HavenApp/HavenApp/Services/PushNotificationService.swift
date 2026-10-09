import Foundation
import UserNotifications
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Manages local notification permission and per-account notification preferences.
///
/// Notifications are generated entirely on-device from the embedded relay's NOTIFY
/// markers (see LocalNotificationService) and from Background App Refresh feed checks —
/// there is no remote push server involved.
@MainActor
class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService()

    @Published var isRegistered: Bool = false
    @Published var lastError: String?

    private init() {
        migrateOldPreferences()
    }

    // MARK: - Per-Account Preferences

    /// Returns notification preferences for a specific account, with defaults if none stored.
    func preferencesForAccount(_ npub: String) -> NotificationPreferences {
        return ConfigService.shared.config.notificationPrefsPerAccount[npub] ?? NotificationPreferences()
    }

    /// Update notification preferences for a specific account.
    func updatePreferences(_ preferences: NotificationPreferences, forAccount npub: String) {
        ConfigService.shared.config.notificationPrefsPerAccount[npub] = preferences
        ConfigService.shared.save()
    }

    /// One-time migration: seed owner account prefs from old global notification_prefs.json if it exists.
    private func migrateOldPreferences() {
        guard ConfigService.shared.config.notificationPrefsPerAccount.isEmpty else { return }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let prefsURL = appSupport.appendingPathComponent("Haven/notification_prefs.json")
        guard let data = try? Data(contentsOf: prefsURL),
              let oldPrefs = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else { return }
        let ownerNpub = ConfigService.shared.config.ownerNpub
        guard !ownerNpub.isEmpty else { return }
        ConfigService.shared.config.notificationPrefsPerAccount[ownerNpub] = oldPrefs
        ConfigService.shared.save()
        try? FileManager.default.removeItem(at: prefsURL)
    }

    // MARK: - Permission

    /// Requests local notification authorization only — no APNs/remote registration.
    func requestPermissionAndRegister() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await MainActor.run {
                self.isRegistered = granted
            }
            if granted {
                print("PushNotificationService: Notification permission granted ✓")
            } else {
                print("PushNotificationService: Notification permission denied")
            }
        }
    }

    // MARK: - Badge Management

    /// Clear the app icon badge. Call this when the app becomes active.
    func clearBadge() {
        #if canImport(UIKit)
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error = error {
                print("PushNotificationService: Failed to clear badge: \(error)")
            }
        }
        #endif
    }

    // MARK: - Feed Notifications (from background refresh)

    /// Called by AppDelegate after a Background App Refresh finds new feed notes.
    static func showFeedNotification(newCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = newCount == 1 ? "New note in your feed" : "\(newCount) new notes in your feed"
        content.body = "People you follow posted while you were away."
        let sound = NotificationSound(rawValue: ConfigService.shared.config.notificationSoundName) ?? .defaultSound
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.systemSoundName))
        content.badge = NSNumber(value: newCount)
        content.categoryIdentifier = "FEED"
        content.userInfo = ["destination": "feed"]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: "haven-feed-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("PushNotificationService: Failed to show feed notification: \(error)")
            }
        }
    }

    // MARK: - Mention/DM Notifications (from in-process relay, foreground)

    /// Fires when the local relay receives a kind-1 mention or kind-4 DM addressed to the owner.
    /// Works while the app is in the foreground (iOS will show the banner via the delegate).
    static func showNoteNotification(event: NostrEvent, senderName: String?) {
        let content = UNMutableNotificationContent()
        let name = senderName ?? String(event.pubkey.prefix(8)) + "…"

        switch event.kind {
        case 4:
            content.title = "DM from \(name)"
            content.body = "Encrypted message"
            content.categoryIdentifier = "DM"
        case 1:
            content.title = "\(name) mentioned you"
            let preview = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = preview.isEmpty ? "New note" : String(preview.prefix(120))
            content.categoryIdentifier = "MENTION"
        default:
            return
        }

        content.sound = .default
        content.userInfo = ["eventId": event.id, "pubkey": event.pubkey, "kind": event.kind, "destination": "viewer"]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "haven-event-\(event.id)",
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("PushNotificationService: Failed to show note notification: \(error)")
            }
        }
    }
}
