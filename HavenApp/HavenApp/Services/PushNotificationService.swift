import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Manages local notification permission, display, and APNs token registration.
///
/// Push architecture supports two modes:
///  1. **Local notifications (default)**: Background App Refresh wakes app periodically
///  2. **Remote push server (optional)**: Mac Mini server monitors relays 24/7
///     - Enable in Settings → Notifications → "Use Remote Push Server"
///     - Configure Mac Mini IP/URL (e.g., http://192.168.1.100:8000)
///     - More reliable, works even when iPhone is offline
@MainActor
class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService()

    @Published var isRegistered: Bool = false
    @Published var isRegisteredWithRemoteServer: Bool = false
    @Published var deviceToken: String?
    @Published var notificationPreferences: NotificationPreferences = NotificationPreferences()

    private init() {
        loadPreferences()
    }

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

    // MARK: - APNs Token

    func didRegister(deviceTokenData: Data) {
        let token = deviceTokenData.map { String(format: "%02.2hhx", $0) }.joined()
        print("PushNotificationService: APNs token received (\(token.prefix(8))…)")
        self.deviceToken = token
        isRegistered = true

        // If remote push server is enabled, register with it
        if ConfigService.shared.config.enableRemotePushServer {
            Task {
                await registerWithRemoteServer(deviceToken: token)
            }
        }
    }

    func didFailToRegister(error: Error) {
        print("PushNotificationService: APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Remote Push Server Integration

    /// Register device with Mac Mini push server
    func registerWithRemoteServer(deviceToken: String) async {
        let config = ConfigService.shared.config
        guard config.enableRemotePushServer, !config.pushServerURL.isEmpty else {
            print("PushNotificationService: Remote push server not enabled")
            return
        }

        let userHexPubkey = NostrService.shared.ownerHexPubkey
        guard !userHexPubkey.isEmpty else {
            print("PushNotificationService: User hex pubkey not available")
            return
        }

        let endpoint = "\(config.pushServerURL)/register"

        let payload: [String: Any] = [
            "device_token": deviceToken,
            "user_hex_pubkey": userHexPubkey,
            "enabled_notifications": [
                "mentions": notificationPreferences.mentions,
                "replies": notificationPreferences.replies,
                "dms": notificationPreferences.dms,
                "zaps": notificationPreferences.zaps,
                "reactions": notificationPreferences.reactions
            ]
        ]

        do {
            guard let url = URL(string: endpoint) else {
                throw NSError(domain: "PushNotificationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "PushNotificationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned error"])
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                isRegisteredWithRemoteServer = true
                print("✅ Successfully registered with remote push server")
            }

        } catch {
            print("❌ Failed to register with remote push server: \(error.localizedDescription)")
        }
    }

    /// Unregister from Mac Mini push server
    func unregisterFromRemoteServer() async {
        guard let deviceToken = deviceToken else { return }

        let config = ConfigService.shared.config
        guard !config.pushServerURL.isEmpty else { return }

        let endpoint = "\(config.pushServerURL)/unregister"

        let payload: [String: Any] = [
            "device_token": deviceToken
        ]

        do {
            guard let url = URL(string: endpoint) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return
            }

            isRegisteredWithRemoteServer = false
            print("✅ Successfully unregistered from remote push server")

        } catch {
            print("❌ Failed to unregister from remote push server: \(error.localizedDescription)")
        }
    }

    /// Update notification preferences (applies to remote server if enabled)
    func updatePreferences(_ preferences: NotificationPreferences) {
        self.notificationPreferences = preferences
        savePreferences()

        // Update remote server if enabled
        if ConfigService.shared.config.enableRemotePushServer, let token = deviceToken {
            Task {
                await registerWithRemoteServer(deviceToken: token)
            }
        }
    }

    private func loadPreferences() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let prefsURL = havenDir.appendingPathComponent("notification_prefs.json")

        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else {
            return
        }

        self.notificationPreferences = prefs
    }

    private func savePreferences() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let prefsURL = havenDir.appendingPathComponent("notification_prefs.json")

        guard let data = try? JSONEncoder().encode(notificationPreferences) else { return }
        try? data.write(to: prefsURL)
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

// MARK: - Models

struct NotificationPreferences: Codable {
    var mentions: Bool = true
    var replies: Bool = true
    var dms: Bool = true
    var zaps: Bool = true
    var reactions: Bool = false
}
