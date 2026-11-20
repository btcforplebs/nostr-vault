#if os(macOS)
import AppKit
import Foundation

/// Settings › Your Vault › Startup › Run in background, and the same switch in
/// the menu bar panel.
///
/// On, the Mac app is a vault engine and nothing else while its window is
/// closed: the relay on its port, Blossom, the mesh and sync keep running,
/// and the window's services (the feed, decoded images, video buffers, log
/// rows, profile fetching) are not started at launch and are let go of when
/// the window closes. The menu bar item still opens the window, which brings
/// them back, or quits.
///
/// Switching never stops, restarts or reconfigures the relay, and writes
/// nothing the vault has stored: the switch is a preference of this Mac
/// (BackgroundModePolicy.defaultsKey), not part of config.json.
@MainActor
final class BackgroundMode: ObservableObject {
    static let shared = BackgroundMode()

    @Published private(set) var isOn: Bool

    /// Set once the window services have been let go of; cleared when the
    /// window opens and they come back.
    private(set) var isReleased = false
    private var trimTimer: Timer?

    private init(defaults: UserDefaults = .standard) {
        isOn = BackgroundModePolicy.isOn(in: defaults)
    }

    /// Whether the window services should run right now.
    var runsWindowServices: Bool {
        BackgroundModePolicy.runsWindowServices(isOn: isOn, windowOpen: MacWindow.isMainWindowMounted)
    }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        UserDefaults.standard.set(on, forKey: BackgroundModePolicy.defaultsKey)
        guard on else {
            // Off with the window closed: the app is the menu bar app it was
            // before. The feed starts again with the window, as it always did.
            stopTrimming()
            if !MacWindow.isMainWindowMounted { restoreWindowServices() }
            return
        }
        let config = ConfigService.shared
        let login = BackgroundModePolicy.launchAtLogin(afterTurningOn: true, current: config.config.launchAtLogin)
        if login != config.config.launchAtLogin {
            config.config.launchAtLogin = login
            config.save()
        }
        if MacWindow.isMainWindowMounted {
            // Closing it runs `mainWindowClosed`, which lets everything go.
            MacWindow.closeMain()
        } else {
            releaseWindowServices()
        }
    }

    /// At launch, before anything draws: a background launch never starts
    /// the window services in the first place.
    func applyAtLaunch() {
        guard isOn else { return }
        releaseWindowServices()
    }

    /// The main window's view tree went away.
    func mainWindowClosed() {
        guard isOn else { return }
        releaseWindowServices()
    }

    /// The main window's view tree is mounting.
    func mainWindowOpened() {
        guard isReleased else { return }
        restoreWindowServices()
    }

    // MARK: - Release and restore

    private func releaseWindowServices() {
        isReleased = true
        // The feed: saved to disk, its relay clients closed, its notes dropped.
        // Paused first thing so a launch never subscribes at all.
        FeedService.shared.releaseForBackground()
        // Decoded full-size images, thumbnails and video buffers.
        MediaCacheService.shared.handleMemoryPressure()
        // URLSession's in-memory response cache; the disk cache stays. The
        // default is read first: the static is lazy, and read after this
        // line it would remember 0.
        _ = Self.defaultMemoryCapacity
        URLCache.shared.memoryCapacity = 0
        // Log rows for the Logs view, and the profile-fetch timer. This also
        // trims the engine's heap once.
        RelayProcessManager.shared.enterBackground()
        RelayProcessManager.shared.logStore.logs.removeAll()
        NostrService.shared.enterBackground()
        startTrimming()
    }

    private func restoreWindowServices() {
        isReleased = false
        stopTrimming()
        URLCache.shared.memoryCapacity = Self.defaultMemoryCapacity
        FillYourVaultCoordinator.shared.start()
        // The window was opened on purpose, so the feed loads now. The rest
        // follows the app's focus as before (AppDelegate's observers); when
        // the app is already in front, bring it back too.
        FeedService.shared.returnFromBackground()
        if NSApp.isActive {
            RelayProcessManager.shared.enterForeground()
            NostrService.shared.enterForeground()
        }
    }

    /// URLCache.shared's own default, read before the first release.
    private static let defaultMemoryCapacity = URLCache.shared.memoryCapacity

    // MARK: - Engine heap

    private func startTrimming() {
        trimTimer?.invalidate()
        trimTimer = Timer.scheduledTimer(withTimeInterval: BackgroundModePolicy.trimInterval, repeats: true) { _ in
            // A full GC: off the main thread, as in RelayProcessManager.
            DispatchQueue.global(qos: .utility).async { TrimMemoryC() }
        }
    }

    private func stopTrimming() {
        trimTimer?.invalidate()
        trimTimer = nil
    }
}
#endif
