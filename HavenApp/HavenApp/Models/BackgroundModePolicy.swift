import Foundation

/// The rules behind the Mac's "Run in background" switch (BackgroundMode),
/// kept free of the app so they can be tested on their own.
///
/// In background mode the Mac app is a vault and nothing else: the relay
/// engine, its port, Blossom, the mesh and sync. Everything that only exists
/// to draw the window (the feed, image caches, log rows) runs only while the
/// window is open, and is let go of when it closes.
enum BackgroundModePolicy {
    /// UserDefaults key. A preference of this Mac, not part of config.json:
    /// switching it changes nothing the vault has stored.
    static let defaultsKey = "nv.mac.runInBackground"

    /// How often the engine's free heap is handed back to macOS while the
    /// window is closed. Sync and import rounds spike the Go heap, and macOS
    /// leaves those pages counted against the app until the runtime returns
    /// them (see TrimMemoryC).
    static let trimInterval: TimeInterval = 300

    static func isOn(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// Whether the window-only services should run now.
    static func runsWindowServices(isOn: Bool, windowOpen: Bool) -> Bool {
        !isOn || windowOpen
    }

    /// A vault that runs in the background has to come back after a restart,
    /// so turning the mode on also turns on Launch at Login. Turning it off
    /// leaves Launch at Login as the person set it.
    static func launchAtLogin(afterTurningOn on: Bool, current: Bool) -> Bool {
        on || current
    }
}
