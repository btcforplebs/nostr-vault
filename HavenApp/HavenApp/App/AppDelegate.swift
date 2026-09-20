import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

@MainActor
class AppDelegate: NSObject, ObservableObject {
    #if os(macOS)
    // Keep a reference to the window prevent it from being deallocated immediately
    private var welcomeWindow: NSWindow?

    // Focus observers are owned for the lifetime of the app, not of a window.
    private var focusResignObserver: NSObjectProtocol?
    private var focusActivateObserver: NSObjectProtocol?
    #endif

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so broken pipe writes (e.g. from the Go relay's
        // stdout redirection) don't silently kill the process.
        signal(SIGPIPE, SIG_IGN)

        #if os(macOS)
        startFocusLifecycleObservers()

        // Without a delegate, a clicked notification only activates the app.
        // LocalNotificationService posts the same notifications on both
        // platforms, but only the iOS app delegate ever answered the tap, so on
        // macOS every one of them — DM, mention, zap, reaction, repost — landed
        // nowhere no matter what the receivers inside the window did.
        UNUserNotificationCenter.current().delegate = self

        // Watch sleep/wake so automatic recovery doesn't restart the relay
        // over connections that are merely re-establishing after wake.
        SleepWakeMonitor.shared.start()

        // Check if setup is complete
        if !ConfigService.shared.config.hasCompletedSetup {
            openWelcomeWindow()
        } else {
            // Auto-start relay after the app is fully initialised.
            // Uses a Task with a brief sleep so the SwiftUI scene and
            // Go runtime are ready before we call into StartRelayC.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard ConfigService.shared.config.autoStartRelay else { return }
                guard RelayProcessManager.shared.state == .idle else { return }
                RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)

                if ConfigService.shared.config.activeSigningMode() == "nip46" {
                    NIP46Service.shared.connectFromConfig()
                }

                // Publish NIP-65 relay lists for accounts with the setting enabled
                try? await Task.sleep(for: .seconds(5))
                NostrService.shared.publishRelayListsForEnabledAccounts()
                // Heals accounts whose kind 10050 still advertises
                // 127.0.0.1 from an older build — replacing it is what
                // makes them reachable again, including from senders
                // still running that build.
                NostrService.shared.republishDMRelayListsForSignableAccounts()

                // Start profile picture prefetch service (runs once per day on Wi-Fi)
                try? await Task.sleep(for: .seconds(5))
                ProfilePicturePrefetchService.shared.start()
            }
        }
        #endif
    }

    #if os(macOS)
    // MARK: - Focus lifecycle

    /// Pause and resume background work when the app loses and regains focus.
    ///
    /// This used to live in `MenuBarView`, which was mounted both as the menu
    /// bar dropdown and as the window. Splitting those two surfaces left
    /// `MenuBarView` mounted only by the window scene — so an app launched to
    /// the menu bar and never opened had no owner for any of it, and the feed,
    /// the external relay sync, log parsing and profile fetching all kept
    /// running while the user was in another application. That is the ordinary
    /// case for a menu bar app, and it is precisely the case a view-scoped
    /// observer cannot cover.
    ///
    /// The app delegate outlives every window, so the ownership belongs here.
    private func startFocusLifecycleObservers() {
        let center = NotificationCenter.default

        focusResignObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // The absence starts now — same bookkeeping as iOS.
                NotificationActivityLog.recordForeground()
                // Pause the feed to reduce background CPU/memory from relay
                // traffic and note accumulation.
                FeedService.shared.pauseFeed()
                // Stop external relay traffic and event injection — reduces log
                // volume, CPU, and prevents pipe backpressure from Go stdout.
                NetworkSyncService.shared.stop()
                // Stop log parsing into UI entries, pause the profile-fetch
                // timer, halt the LogStore publishing timer.
                RelayProcessManager.shared.enterBackground()
                NostrService.shared.enterBackground()
            }
        }

        focusActivateObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Ends any absence for the catch-up summary (NotificationPolicy).
                NotificationActivityLog.recordForeground()
                FeedService.shared.resumeFeed()
                NetworkSyncService.shared.start()
                RelayProcessManager.shared.enterForeground()
                NostrService.shared.enterForeground()
            }
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        print("Application terminating, stopping relay...")
        #endif

        // Persist the current feed so the next cold launch restores it instantly.
        // The encode + write runs off-main; the relay-stop semaphore wait below
        // gives it time to flush before the process exits.
        FeedService.shared.persistCurrentSnapshot()

        // Stop background services before relay shutdown
        NetworkSyncService.shared.stop()
        NIP46Service.shared.disconnect()

        // Stop the relay directly, bypassing the serialized lifecycle chain —
        // termination must not wait behind a queued backup or restart. The Go
        // side's lifecycle mutex makes a direct StopRelayC safe even against
        // an in-flight operation, and stopping an already-stopped relay is a
        // no-op. We block briefly so the process doesn't exit before the Go
        // side has flushed and closed the databases.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            StopRelayC()
            semaphore.signal()
        }
        // Wait up to 5 seconds for a clean shutdown; if it takes longer the
        // OS will SIGKILL us anyway.
        _ = semaphore.wait(timeout: .now() + 5.0)
    }
    
    func openWelcomeWindow() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        
        // Prepare the content view with shared environment objects
        let contentView = SetupWizardView { [weak window] in
            // On complete:
            #if DEBUG
            print("Setup complete, starting relay from AppDelegate...")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
            }
            window?.close()
        }
        .environmentObject(ConfigService.shared)
        .environmentObject(RelayProcessManager.shared)
        .environmentObject(NostrService.shared)
        .environmentObject(StatsService.shared)
        .frame(minWidth: 500, minHeight: 650)
        
        window.contentView = NSHostingView(rootView: contentView)
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        window.level = .normal // Standard window level
        NSApp.activate(ignoringOtherApps: true)
        
        self.welcomeWindow = window
    }
    #endif
}

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {}

// MARK: - Notification taps (macOS)

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// macOS suppresses notifications for the frontmost app unless the delegate
    /// asks for them. LocalNotificationService only posts these when the app is
    /// not foregrounded on iOS; on macOS `appInForeground` is never set, and the
    /// in-app banner (RelayActivityBanner) is only hosted by the iOS view tree —
    /// so this is the only way a message that arrives while the app is active is
    /// visible at all.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let type = userInfo["notif_type"] as? String,
              let id = userInfo["notif_id"] as? String else {
            completionHandler()
            return
        }
        let npub = userInfo["notif_npub"] as? String
        Task { @MainActor in
            AppDelegate.deliverNotificationTap(type: type, id: id, npub: npub)
        }
        completionHandler()
    }

    /// Routes a tapped notification into the main window.
    ///
    /// Every receiver of the `.havenOpen*` routes lives in that window's view
    /// tree, and a menu bar app is usually running with no window open — so
    /// posting unconditionally is how a click does nothing. When the tree is
    /// mounted the post reaches it; when it is not, the route is parked and the
    /// window replays it as it mounts.
    @MainActor
    static func deliverNotificationTap(type: String, id: String, npub: String?) {
        if MacWindow.isMainWindowMounted {
            MacWindow.openMainFromAppKit()
            LocalNotificationService.navigate(type: type, id: id, npub: npub)
        } else {
            MacWindow.pendingRoute = MacWindow.NotificationRoute(type: type, id: id, npub: npub)
            MacWindow.openMainFromAppKit()
            // Safety net for a stale `isMainWindowMounted == false`. That flag
            // is view-tree bookkeeping kept by onAppear/onDisappear, so a
            // window that is really on screen but recorded as gone would park a
            // route nothing ever consumes — the exact silent failure this
            // method exists to remove. Consuming is what makes the two paths
            // safe together: whichever gets there first clears the route, so a
            // tap cannot be handled twice. The mounted check is deliberately
            // before the consume — if the window genuinely has not mounted yet,
            // the route stays parked for `onAppear` instead of being dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard MacWindow.isMainWindowMounted,
                          let route = MacWindow.consumePendingRoute() else { return }
                    LocalNotificationService.navigate(type: route.type, id: route.id, npub: route.npub)
                }
            }
        }
    }
}
#endif
