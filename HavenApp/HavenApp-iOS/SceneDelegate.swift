import UIKit
import SwiftUI
import BackgroundTasks

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        // A widget tap can be what launched us. The UI is not up yet, so defer
        // the route until after the first render -- posting into an empty
        // NotificationCenter here would be dropped on the floor.
        if let url = connectionOptions.urlContexts.first?.url {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NVDeepLinkRouter.handle(url)
            }
        }

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
        
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()

        // In-app banners and the zap strike get a window of their own, above
        // the app's, so a sheet (a profile, a note, compose) can never cover them. It takes
        // no touches except on the banners themselves.
        let banners = BannerWindow(windowScene: windowScene)
        banners.windowLevel = .alert - 1
        banners.overrideUserInterfaceStyle = .dark
        // The zap strike flies here too: drawn in the app's own window, a bolt
        // fired from a profile or a note sheet went off behind that sheet.
        let host = UIHostingController(rootView: ZStack {
            ZapFlightStage()
            AppBannerStack()
        })
        host.view.backgroundColor = .clear
        banners.rootViewController = host
        banners.isHidden = false
        self.bannerWindow = banners
    }

    var bannerWindow: UIWindow?

    func sceneDidDisconnect(_ scene: UIScene) {
        // Stop through the manager, never StopRelayC() directly:
        // 1. The process often survives a scene disconnect. A direct call left
        //    state/isRunning stale (.running), so the next scene connect could
        //    never restart the relay and the feed reconnected into a dead
        //    local socket (silent "feed never refreshes" until force-kill).
        // 2. A synchronous call blocked the main thread inside the Go runtime
        //    past iOS's 5s termination budget — the 0x8BADF00D watchdog kills.
        // stopRelay() runs the Go shutdown on a background queue and resets
        // state to .idle when done.
        RelayProcessManager.shared.stopRelay()
    }

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Widget tap while the app is already running.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        Task { @MainActor in NVDeepLinkRouter.handle(url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // End the background task if the user has returned to the app.
        endBackgroundTask()

        // Refresh what the widgets read. Rate limited inside the bridge, since
        // scene activation fires more often than the data meaningfully changes.
        Task { @MainActor in NVWidgetBridge.publish() }

        // Show the in-app banner (not a system push) for relay activity while visible.
        LocalNotificationService.shared.appInForeground = true

        // The user is here: this ends any absence, and the feed on screen counts
        // as seen, so the next "N new notes in your feed" starts from here.
        NotificationActivityLog.recordForeground()
        if let newest = FeedService.shared.notes.map(\.createdAt).max() {
            NotificationActivityLog.recordAnnouncedFeedNote(newest)
        }

        // Clear app badge and reset server-side badge counter
        Task { @MainActor in
            PushNotificationService.shared.clearBadge()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Back to system push notifications once the app leaves the foreground.
        LocalNotificationService.shared.appInForeground = false

        // The absence starts now — recorded on the way out as well as on the way
        // in, so a long session doesn't read as a long absence.
        NotificationActivityLog.recordForeground()
        if let newest = FeedService.shared.notes.map(\.createdAt).max() {
            NotificationActivityLog.recordAnnouncedFeedNote(newest)
        }

        // Publish on the way out too: this is the state the user will see on
        // the Home Screen a second from now, and it is the last chance to
        // capture it before the process is suspended.
        Task { @MainActor in NVWidgetBridge.publish(force: true) }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Check the NIP-46 signer session survived the suspension; reconnect
        // only if it no longer answers.
        NIP46Service.shared.resumeAfterForeground()

        // Reconnect immediately — REQs go out from each socket's .connected
        // event, so a fixed "settle" delay only adds latency. The relay is
        // in-process and un-freezes the moment we foreground; if it is still
        // booting, FeedService's $isReadyForConnections observer re-runs the
        // reconcile once it's up (the feed must be unpaused before then,
        // which is why resumeFeed() is not gated on isRunning — the old
        // one-shot `guard isRunning` bail was a silent "feed never
        // refreshes until pull-to-refresh").
        NostrService.shared.resetConnections()
        // Mark that we handled foreground reconnection so ViewerView
        // doesn't redundantly call refreshAll() on its next onAppear.
        NostrService.shared.lastForegroundReconnectTime = Date()

        // Reconnect feed WebSocket connections killed during suspend.
        // Suspension kills sockets without flipping their state, so if the
        // background handler didn't get to pause the feed, cycle it to clear
        // zombie connections; resumeFeed() routes through the idempotent
        // reconciler which reconnects only what's missing.
        if !FeedService.shared.isPaused {
            FeedService.shared.pauseFeed()
        }
        FeedService.shared.resumeFeed()

        // Re-fetch the viewer (Relay tab) notes if the relay is up. If it
        // isn't yet, ViewerView refreshes on its own appear path.
        if RelayProcessManager.shared.isRunning {
            let config = ConfigService.shared.config
            var urls = [config.nostrURL, config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
            let macURL = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
                urls.append(macInbox)
            }
            if !urls.isEmpty {
                NostrService.shared.fetchNotes(from: urls)
            }
        }

        // Rescan blossom directory for media that arrived while backgrounded
        NotificationCenter.default.post(name: .blossomDirectoryChanged, object: nil)

        // Refresh DM inbox to pick up messages received while backgrounded
        DMService.shared.refresh()


        // Sync DMs from external relays on foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            DMService.shared.syncOnForeground()
        }

        // Returning to the app is a return from absence: with a Mac relay set,
        // ask the relay for a catch-up round (the Mac is one of its relays) that
        // may end in a "while you were away" summary.
        if !RelayConfiguration.macRelayURL(config: ConfigService.shared.config).isEmpty {
            RequestCatchUpC()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // The NIP-46 signer session is deliberately kept: approving a request
        // means switching to the signer app, and disconnecting here killed the
        // request the moment the user left to approve it. Outstanding requests
        // hold a background task (NIP46Service.signerRequest).

        // Persist the current feed to disk so the next cold launch can restore
        // it instantly. Must run before pauseFeed() while notes are still in
        // memory; the encode + write happens off-main inside the background-task
        // window opened below.
        FeedService.shared.persistCurrentSnapshot()

        // Pause feed & reset viewer connections when entering background
        FeedService.shared.pauseFeed()
        NostrService.shared.resetConnections()

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

/// A window that passes every touch through to the app below, except
/// touches that land on something it draws (a banner's button).
final class BannerWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event),
              let root = rootViewController?.view else { return nil }
        if #available(iOS 18.0, *) {
            // SwiftUI content no longer shows up as separate hit views: the
            // hosting view answers for all of it. Ask its drawn layers instead,
            // and pass the touch on when nothing is drawn under it.
            for subview in root.subviews.reversed() {
                let converted = subview.convert(point, from: root)
                guard let target = subview.hitTest(converted, with: event) else { continue }
                // Never claim a screen-sized view: if the banner layout ever
                // grew a full-size layer, taking its touches would freeze the
                // app underneath. Fail toward passing the touch through.
                let size = target.bounds.size
                if size.width >= root.bounds.width && size.height >= root.bounds.height * 0.5 { continue }
                return hit
            }
            return nil
        }
        return hit === root ? nil : hit
    }
}

/// Every in-app banner, top-centred below the navigation bar.
struct AppBannerStack: View {
    var body: some View {
        VStack(spacing: 6) {
            SignerApprovalBanner()
            PostActionNotificationBanner()
            ZapNotificationBanner()
            FollowNotificationBanner()
            MediaUploadNotificationBanner()
            RelayActivityBanner()
            ActionToastBanner()
            ErrorNotificationBanner()
            Spacer(minLength: 0)
        }
        // Below the navigation bar (44 pt on iPhone, 50 pt on iPad), not over its buttons.
        .padding(.top, 4 + (UIDevice.current.userInterfaceIdiom == .pad ? 50 : 44))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
