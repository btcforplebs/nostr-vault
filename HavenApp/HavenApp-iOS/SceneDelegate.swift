import UIKit
import SwiftUI
import BackgroundTasks

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        // NOTE: Do NOT call StartRelayC here directly.
        // RelayProcessManager.startRelay() is called from ContentView.onAppear,
        // which also updates all state flags (isRunning, isBooting, etc.).
        // Calling StartRelayC() directly here bypasses that state management,
        // leaving relayManager.isRunning = false forever, which causes the
        // ViewerView notes fetch guard to always bail.

        let window = UIWindow(windowScene: windowScene)
        
        let configService = ConfigService.shared
        let relayManager = RelayProcessManager.shared
        let nostrService = NostrService.shared
        let statsService = StatsService.shared
        
        let contentView = ContentView()
            .environmentObject(configService)
            .environmentObject(relayManager)
            .environmentObject(nostrService)
            .environmentObject(statsService)
            .environmentObject(AppState.shared)
        
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // RelayProcessManager.shared.stopRelay() is the proper way to stop,
        // but on disconnect we can call StopRelayC directly since the app is going away.
        StopRelayC()
    }

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBecomeActive(_ scene: UIScene) {
        // End the background task if the user has returned to the app.
        endBackgroundTask()
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Reconnect the notes WebSocket after the app was suspended.
        // The relay is still in-process; it un-freezes the moment we foreground.
        // Give it a second to settle then re-fetch notes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard RelayProcessManager.shared.isRunning else { return }
            NostrService.shared.resetConnections()
            let config = ConfigService.shared.config
            let urls = [
                URL(string: config.nostrURL)!,
                URL(string: config.nostrURL + "/inbox")!
            ]
            NostrService.shared.fetchNotes(from: urls)
        }
        
        // Sync missed notes from Mac relay (if configured)
        // Delay slightly longer to ensure local relay is fully ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            MacRelaySyncService.shared.syncIfConfigured()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Request background execution time from iOS.
        // This gives ~30 seconds for the relay goroutines to finish in-flight work
        // (e.g. writing an event to BadgerDB) before the process is suspended.
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "relay-wind-down") { [weak self] in
            // Expiry handler: iOS is about to suspend us. Wrap up.
            self?.endBackgroundTask()
        }

        // Also schedule a BGProcessingTask so iOS can wake us later
        // (e.g. when plugged in and on Wi-Fi) for a longer relay window.
        AppDelegate.scheduleBackgroundProcessing()
    }

    // MARK: - Helpers

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}