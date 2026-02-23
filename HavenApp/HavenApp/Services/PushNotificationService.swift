import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Manages local notification permission, display, and APNs token registration.
///
/// Push architecture (no external server required):
///  - iOS Background App Refresh periodically wakes the app.
///  - AppDelegate calls FeedService.refresh() to open WebSockets to public Nostr relays.
///  - If new notes arrive from followed pubkeys, showFeedNotification() fires a local banner.
///  - For mentions/DMs to the owner, showNoteNotification() fires when the in-process relay
///    receives a matching event while the app is in the foreground.
@MainActor
class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService()

    @Published var isRegistered: Bool = false

    private init() {}

    // MARK: - Permission & Registration

    func requestPermissionAndRegister() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await MainActor.run {
                self.isRegistered = granted
            }
            if granted {
                print("PushNotificationService: Notification permission granted ✓")
                // Enable Background App Refresh wakeups
                #if canImport(UIKit)
                UIApplication.shared.registerForRemoteNotifications()
                #endif
            } else {
                print("PushNotificationService: Notification permission denied")
            }
        }
    }

    // MARK: - APNs Token (for Background App Refresh wakeups)

    func didRegister(deviceTokenData: Data) {
        let token = deviceTokenData.map { String(format: "%02.2hhx", $0) }.joined()
        print("PushNotificationService: APNs token received (\(token.prefix(8))…)")
        isRegistered = true
    }

    func didFailToRegister(error: Error) {
        print("PushNotificationService: APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Feed Notifications (from background refresh)

    /// Called by AppDelegate after a Background App Refresh finds new feed notes.
    static func showFeedNotification(newCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = newCount == 1 ? "New note in your feed" : "\(newCount) new notes in your feed"
        content.body = "People you follow posted while you were away."
        content.sound = .default
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
