import UIKit
import BackgroundTasks
import UserNotifications

/// Background task identifiers — must also be declared in Info.plist under
/// BGTaskSchedulerPermittedIdentifiers.
private let kBGProcessingTaskID = "com.haven.relay.processing"

private let kBGRefreshTaskID = "com.haven.relay.refresh"

/// Queued notification action to replay once the UI is ready.
struct PendingNotificationAction {
    let eventId: String?
    let eventKind: Int
    let recipientPubkey: String?
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// When `true`, the app allows landscape orientation (used by media viewers).
    static var allowLandscape = false

    /// Stores a pending notification action when the relay isn't ready yet.
    /// ContentView replays this once the relay is running and views are mounted.
    static var pendingAction: PendingNotificationAction?

    /// Dispatches a notification action immediately (posts NSNotification + triggers refresh).
    static func dispatchAction(_ action: PendingNotificationAction) {
        pendingAction = nil
        Task { @MainActor in
            // Switch to the correct account if the notification is for a different one
            if let recipientHex = action.recipientPubkey,
               !recipientHex.isEmpty,
               let hexData = Data(hexString: recipientHex),
               let npub = Bech32.encode(hrp: "npub", data: hexData) {
                ConfigService.shared.switchActiveAccount(to: npub)
            }

            switch action.eventKind {
            case 1059, 4:
                DMService.shared.refresh()
                NotificationCenter.default.post(name: .havenOpenDMInbox, object: nil)
            case 1:
                NotificationCenter.default.post(name: .havenOpenMentions, object: action.eventId)
            case 7:
                NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
            case 6:
                NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
            case 9735:
                NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
            default:
                break
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register the background processing task so the system can wake us
        // when conditions are right (charging + Wi-Fi).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: kBGProcessingTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleBackgroundProcessingTask(processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: kBGRefreshTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleAppRefreshTask(refreshTask)
        }

        // Set notification center delegate
        UNUserNotificationCenter.current().delegate = self

        // Only request local notification permission if the user has already
        // completed setup (has an npub). First-time users will be prompted
        // after the setup wizard finishes. No remote/APNs registration —
        // notifications are generated on-device from the relay's NOTIFY markers.
        if ConfigService.shared.config.hasCompletedSetup {
            Task { @MainActor in
                PushNotificationService.shared.requestPermissionAndRegister()
            }
            Self.scheduleAppRefresh()
        }

        return true
    }

    // MARK: - Orientation Lock

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if Self.allowLandscape {
            return [.portrait, .landscapeLeft, .landscapeRight]
        }
        return .portrait
    }

    // MARK: - Background App Refresh (no push server needed!)

    /// Starts the relay if a prior force-quit stopped it (SceneDelegate.sceneDidDisconnect
    /// calls stopRelay(), so a background wake after a full quit finds isRunning == false),
    /// then waits up to `maxBootWaitSeconds` for it to leave the booting state. Without this,
    /// the catch-up request below reaches no relay for the entire background window
    /// whenever the app wasn't just backgrounded but fully quit.
    private static func ensureRelayRunning(maxBootWaitSeconds: Int) async {
        if !RelayProcessManager.shared.isRunning {
            RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
        }
        var waited = 0
        while RelayProcessManager.shared.isBooting && waited < maxBootWaitSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
    }

    static func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task { @MainActor in
            FeedService.shared.refresh()

            // Sync DMs from external relays
            DMService.shared.syncOnForeground()

            // With a Mac relay set, catch up from it (and the other relays):
            // new events land in the local relay and notify through the same
            // NOTIFY-marker pipeline as live events. A relay that was just
            // started runs this round on its own shortly after boot.
            await ensureRelayRunning(maxBootWaitSeconds: 10)
            if !RelayConfiguration.macRelayURL(config: ConfigService.shared.config).isEmpty {
                RequestCatchUpC()
            }

            // Give it up to 25s to connect to relays and receive events
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            announceFeedActivityIfWanted()
            task.setTaskCompleted(success: true)
        }
    }

    /// Announces feed activity from a background wake — but only when the user
    /// asked for it, and only once per genuine absence.
    ///
    /// This wake fires as often as iOS grants it. It used to notify on every
    /// one, counting the growth of `FeedService.notes` over the 25-second window
    /// above (which counts backfilled older notes as news) and checking no
    /// preference at all — not even the master Notifications switch, which is
    /// why turning notifications off never stopped it.
    @MainActor
    private static func announceFeedActivityIfWanted() {
        let config = ConfigService.shared.config
        let dates = FeedService.shared.notes.map(\.createdAt)

        guard config.enablePushNotifications, config.enableFeedNotifications else { return }
        guard NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: Date(),
            lastForegroundAt: NotificationActivityLog.lastForegroundAt,
            lastAnnouncedAt: NotificationActivityLog.lastFeedSummaryAt
        ) else { return }

        let newCount = NotificationPolicy.unannouncedFeedNoteCount(
            createdAt: dates,
            lastAnnouncedNoteAt: NotificationActivityLog.lastAnnouncedFeedNoteAt
        )
        guard newCount > 0 else { return }

        // Watermark forward only when the user is actually told: a wake that
        // stays silent must not consume the notes it stayed silent about.
        // Foregrounding the app moves it too (SceneDelegate) — those notes were
        // on screen.
        NotificationActivityLog.recordFeedSummary()
        if let newest = dates.max() { NotificationActivityLog.recordAnnouncedFeedNote(newest) }
        PushNotificationService.showFeedNotification(newCount: newCount)
    }

    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: kBGRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        try? BGTaskScheduler.shared.submit(request)
    }


    // MARK: UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}

    // MARK: - Background Processing Task

    /// Called by BGTaskScheduler when the system grants background processing time
    /// (requires charging + Wi-Fi, so windows are typically longer and less frequent
    /// than BGAppRefreshTask — a good fit for the same relay-start + Mac-relay-sync
    /// work with more generous timing).
    private static func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        scheduleBackgroundProcessing()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task { @MainActor in
            await ensureRelayRunning(maxBootWaitSeconds: 20)
            if !RelayConfiguration.macRelayURL(config: ConfigService.shared.config).isEmpty {
                RequestCatchUpC()
            }

            // More generous window than BGAppRefreshTask — this task only runs
            // when iOS grants a longer, less time-pressured slot.
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            task.setTaskCompleted(success: true)
        }
    }

    /// Schedule the next BGProcessingTask request.
    static func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: kBGProcessingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner, play sound, and update badge even when app is open
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            PushNotificationService.shared.clearBadge()
        }

        let userInfo = response.notification.request.content.userInfo

        if let eventId = userInfo["event_id"] as? String,
           let eventKind = userInfo["event_kind"] as? Int {
            let recipientPubkey = userInfo["recipient_pubkey"] as? String
            let action = PendingNotificationAction(eventId: eventId, eventKind: eventKind, recipientPubkey: recipientPubkey)

            // If the relay is already running, dispatch immediately.
            // Otherwise queue for ContentView to replay when ready.
            if RelayProcessManager.shared.isRunning {
                Self.dispatchAction(action)
            } else {
                Self.pendingAction = action
            }
        } else if let notifType = userInfo["notif_type"] as? String,
                  let notifId = userInfo["notif_id"] as? String {
            // Tapped a relay NOTIFY-marker notification (LocalNotificationService).
            let notifNpub = userInfo["notif_npub"] as? String
            Task { @MainActor in
                LocalNotificationService.navigate(type: notifType, id: notifId, npub: notifNpub)
            }
        }

        completionHandler()
    }
}
