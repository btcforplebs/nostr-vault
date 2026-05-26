import UIKit
import BackgroundTasks
import UserNotifications

/// Background task identifiers — must also be declared in Info.plist under
/// BGTaskSchedulerPermittedIdentifiers.
private let kBGProcessingTaskID = "com.haven.relay.processing"

private let kBGRefreshTaskID = "com.haven.relay.refresh"

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

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
            Self.handleBackgroundProcessingTask(task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: kBGRefreshTaskID,
            using: nil
        ) { task in
            Self.handleAppRefreshTask(task as! BGAppRefreshTask)
        }

        // Set notification center delegate
        UNUserNotificationCenter.current().delegate = self

        return true
    }

    // MARK: - Remote Notifications (APNs)

    /// Called when APNs registration succeeds
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didRegister(deviceTokenData: deviceToken)
        }
    }

    /// Called when APNs registration fails
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegister(error: error)
        }
    }

    // MARK: - Background App Refresh (no push server needed!)

    static func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task { @MainActor in
            let countBefore = FeedService.shared.notes.count
            FeedService.shared.refresh()
            
            // Also sync from Mac relay if configured
            MacRelaySyncService.shared.syncIfConfigured()
            
            // Give it up to 25s to connect to relays and receive events
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            let newCount = FeedService.shared.notes.count - countBefore
            if newCount > 0 {
                task.setTaskCompleted(success: true)
            } else {
                task.setTaskCompleted(success: true)
            }
        }
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

    /// Called by BGTaskScheduler when the system grants background processing time.
    private static func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        scheduleBackgroundProcessing()
        task.expirationHandler = {
            task.setTaskCompleted(success: true)
        }
        task.setTaskCompleted(success: true)
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
        let userInfo = response.notification.request.content.userInfo

        // Extract event details from remote push notification
        if let eventId = userInfo["event_id"] as? String,
           let eventKind = userInfo["event_kind"] as? Int {
            print("📬 User tapped notification for event \(eventId) (kind \(eventKind))")

            // Navigate to appropriate view based on event kind
            switch eventKind {
            case 1059, 4:
                // Open DM inbox
                NotificationCenter.default.post(name: NSNotification.Name("OpenDMInbox"), object: nil)
            case 1:
                // Open mentions/replies
                NotificationCenter.default.post(name: NSNotification.Name("OpenMentions"), object: eventId)
            case 9735:
                // Open wallet/zaps view
                NotificationCenter.default.post(name: NSNotification.Name("OpenWallet"), object: nil)
            default:
                break
            }
        }

        completionHandler()
    }
}
