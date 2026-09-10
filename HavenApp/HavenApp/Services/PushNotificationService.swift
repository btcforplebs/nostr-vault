import Foundation
import UserNotifications
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Manages push notification permission, APNs token registration, and per-account preferences.
///
/// When push notifications are enabled, registers each account with the push server
/// using account-specific notification preferences (mentions, replies, DMs, zaps, reactions, reposts).
@MainActor
class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService()

    nonisolated private static let pushAPIKey = "d7f837ddc6d52817f4eead434a4a7786582595735ae7db817720af4c8404e397"

    @Published var isRegistered: Bool = false
    @Published var isRegisteredWithRemoteServer: Bool = false
    @Published var deviceToken: String?
    @Published var lastError: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        migrateOldPreferences()
        observeAccountChanges()
    }

    // MARK: - Per-Account Preferences

    /// Returns notification preferences for a specific account, with defaults if none stored.
    func preferencesForAccount(_ npub: String) -> NotificationPreferences {
        return ConfigService.shared.config.notificationPrefsPerAccount[npub] ?? NotificationPreferences()
    }

    /// Update notification preferences for a specific account and sync to server.
    func updatePreferences(_ preferences: NotificationPreferences, forAccount npub: String) {
        ConfigService.shared.config.notificationPrefsPerAccount[npub] = preferences
        ConfigService.shared.save()

        if ConfigService.shared.config.enablePushNotifications, let token = deviceToken {
            guard let decoded = Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            let hexPubkey = decoded.hexString
            guard !hexPubkey.isEmpty else { return }
            Task {
                await registerWithRemoteServer(deviceToken: token, userHexPubkey: hexPubkey, preferences: preferences)
            }
        }
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

    // MARK: - Account Changes

    /// Automatically re-register all accounts when the whitelisted accounts list changes
    private func observeAccountChanges() {
        ConfigService.shared.$config
            .map { $0.whitelistedNpubs }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard ConfigService.shared.config.enablePushNotifications,
                      let token = self.deviceToken else { return }

                print("🔄 Account list changed - re-registering all accounts with push server")
                Task {
                    await self.registerAllAccountsWithRemoteServer(deviceToken: token)
                }
            }
            .store(in: &cancellables)
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

        // If push notifications are enabled, register all accounts
        if ConfigService.shared.config.enablePushNotifications {
            Task {
                await registerAllAccountsWithRemoteServer(deviceToken: token)
            }
        }
    }

    func didFailToRegister(error: Error) {
        print("PushNotificationService: APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Remote Push Server Integration

    /// Register all accounts (owner + whitelisted) with the push server
    func registerAllAccountsWithRemoteServer(deviceToken: String) async {
        let config = ConfigService.shared.config
        guard config.enablePushNotifications, !config.pushServerURL.isEmpty else {
            print("PushNotificationService: Push notifications not enabled")
            return
        }

        // Validate token format (should be hex string, 64+ chars)
        guard deviceToken.count >= 64,
              deviceToken.allSatisfy({ $0.isHexDigit }) else {
            lastError = "Invalid device token format"
            print("PushNotificationService: Invalid device token format (\(deviceToken.prefix(8))…)")
            return
        }

        lastError = nil

        for npub in ConfigService.shared.allAccountNpubs {
            guard let decoded = Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            let hexPubkey = decoded.hexString
            guard !hexPubkey.isEmpty else { continue }
            let prefs = preferencesForAccount(npub)
            await registerWithRemoteServer(deviceToken: deviceToken, userHexPubkey: hexPubkey, preferences: prefs)
        }
    }

    /// Register a single pubkey with the push server (with 1 retry)
    private func registerWithRemoteServer(deviceToken: String, userHexPubkey: String, preferences: NotificationPreferences) async {
        for attempt in 1...2 {
            let success = await attemptRegistration(deviceToken: deviceToken, userHexPubkey: userHexPubkey, preferences: preferences)
            if success { return }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s before retry
            }
        }
    }

    private func attemptRegistration(deviceToken: String, userHexPubkey: String, preferences: NotificationPreferences) async -> Bool {
        let config = ConfigService.shared.config
        let endpoint = "\(config.pushServerURL)/register"

        let payload: [String: Any] = [
            "device_token": deviceToken,
            "user_hex_pubkey": userHexPubkey,
            "enabled_notifications": [
                "mentions": preferences.mentions,
                "replies": preferences.replies,
                "dms": preferences.dms,
                "zaps": preferences.zaps,
                // Zaps Only mode hard-disables reaction pushes regardless of the stored preference.
                "reactions": config.zapsOnlyMode ? false : preferences.reactions,
                "reposts": preferences.reposts
            ]
        ]

        do {
            guard let url = URL(string: endpoint) else {
                lastError = "Invalid push server URL"
                return false
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.pushAPIKey, forHTTPHeaderField: "X-API-Key")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "No response from push server"
                return false
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                lastError = "Push server returned HTTP \(httpResponse.statusCode)"
                return false
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                isRegisteredWithRemoteServer = true
                lastError = nil
                print("✅ Registered \(userHexPubkey.prefix(16))… with push server")
                return true
            }

            lastError = "Push server returned unexpected response"
            return false

        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                lastError = "Connection timed out. Is the push server running?"
            case .cannotConnectToHost, .cannotFindHost:
                lastError = "Cannot connect to push server. Check the URL."
            case .networkConnectionLost, .notConnectedToInternet:
                lastError = "No network connection"
            default:
                lastError = "Network error: \(error.localizedDescription)"
            }
            print("❌ Failed to register \(userHexPubkey.prefix(16))…: \(error.localizedDescription)")
            return false
        } catch {
            lastError = error.localizedDescription
            print("❌ Failed to register \(userHexPubkey.prefix(16))…: \(error.localizedDescription)")
            return false
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
            request.setValue(Self.pushAPIKey, forHTTPHeaderField: "X-API-Key")
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


    // MARK: - Badge Management

    /// Clear the app icon badge and reset the server-side badge counter.
    /// Call this when the app becomes active.
    func clearBadge() {
        #if canImport(UIKit)
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error = error {
                print("PushNotificationService: Failed to clear badge: \(error)")
            }
        }
        #endif

        // Reset server-side badge counter
        guard let token = deviceToken,
              ConfigService.shared.config.enablePushNotifications,
              !ConfigService.shared.config.pushServerURL.isEmpty else { return }

        let endpoint = "\(ConfigService.shared.config.pushServerURL)/badge/reset"
        Task.detached {
            guard let url = URL(string: endpoint) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(PushNotificationService.pushAPIKey, forHTTPHeaderField: "X-API-Key")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_token": token])
            request.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: request)
        }
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

struct NotificationPreferences: Codable, Equatable {
    var mentions: Bool = true
    var replies: Bool = true
    var dms: Bool = true
    var zaps: Bool = true
    var reactions: Bool = false
    var reposts: Bool = false
}
