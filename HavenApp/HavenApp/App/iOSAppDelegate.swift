import SwiftUI
#if os(iOS)
import UIKit
import AVFoundation

@MainActor
class iOSAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Ignore SIGPIPE so broken pipe writes don't kill the process
        signal(SIGPIPE, SIG_IGN)

        // Configure audio session to allow mixing with other apps (e.g., Music)
        // This prevents muted videos from interrupting background music playback
        configureAudioSession()

        // Auto-start relay on launch
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard ConfigService.shared.config.autoStartRelay else { return }
            guard ConfigService.shared.config.hasCompletedSetup else { return }
            guard RelayProcessManager.shared.state == .idle else { return }

            #if DEBUG
            print("iOS: Auto-starting relay on launch...")
            #endif

            RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)

            if ConfigService.shared.config.activeSigningMode() == "nip46" {
                NIP46Service.shared.connectFromConfig()
            }

            // Publish NIP-65 relay lists for accounts with the setting enabled
            try? await Task.sleep(for: .seconds(5))
            NostrService.shared.publishRelayListsForEnabledAccounts()

            // Start profile picture prefetch service (runs once per day on Wi-Fi)
            try? await Task.sleep(for: .seconds(5))
            ProfilePicturePrefetchService.shared.start()
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        #if DEBUG
        print("iOS: App entering background - requesting background time to keep relay alive")
        #endif

        // Persist the current feed so the next cold launch restores it instantly.
        FeedService.shared.persistCurrentSnapshot()

        // Request background time to keep relay running
        backgroundTask = application.beginBackgroundTask { [weak self] in
            #if DEBUG
            print("iOS: Background time expiring - cleaning up")
            #endif
            self?.endBackgroundTask()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        #if DEBUG
        print("iOS: App entering foreground - ending background task")
        #endif

        // End background task when returning to foreground
        endBackgroundTask()

        // Check if relay is still running, restart if needed
        Task { @MainActor in
            if ConfigService.shared.config.autoStartRelay &&
               ConfigService.shared.config.hasCompletedSetup &&
               RelayProcessManager.shared.state == .idle {
                #if DEBUG
                print("iOS: Relay stopped while backgrounded, restarting...")
                #endif
                RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
            }

            // Catch up on DMs that arrived while backgrounded and re-open the
            // live external DM subscription (sockets are suspended in background).
            DMService.shared.syncOnForeground()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        #if DEBUG
        print("iOS: Application terminating, stopping relay...")
        #endif

        RelayProcessManager.shared.stopRelay()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Set category to .ambient with .mixWithOthers so muted videos don't interrupt music
            // Don't activate the session yet - let AVPlayer activate it only when needed
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            #if DEBUG
            print("iOS: Audio session category configured for ambient playback (won't interrupt background music)")
            #endif
        } catch {
            #if DEBUG
            print("iOS: Failed to configure audio session: \(error)")
            #endif
        }
    }
}
#endif
