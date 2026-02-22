import UIKit
import BackgroundTasks
import UserNotifications

/// Background task identifiers — must also be declared in Info.plist under
/// BGTaskSchedulerPermittedIdentifiers.
private let kBGProcessingTaskID = "com.haven.relay.processing"

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
        
        // Enable Background App Refresh — iOS will call performFetch on its schedule
        // (typically every 15-30 min) without any push server needed.
        UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

        return true
    }

    // MARK: - Background App Refresh (no push server needed!)

    /// iOS calls this periodically when Background App Refresh is enabled in Settings.
    /// We connect directly to public Nostr relays to look for new notes from followed
    /// pubkeys. If new ones arrive, we show a local notification.
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            let countBefore = FeedService.shared.notes.count
            FeedService.shared.refresh()
            // Give it up to 25s to connect to relays and receive events
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            let newCount = FeedService.shared.notes.count - countBefore
            if newCount > 0 {
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        }
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
