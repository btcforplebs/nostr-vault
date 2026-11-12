import Foundation

/// One scan of the vault's media folder at a time, without losing a request.
///
/// The gallery used to drop any rescan asked for while one was running
/// (`if isScanning { return }`). Files land in bursts (Auto-Mirror, a Mirror
/// from the feed, a photo from another device), so the request for the last
/// file often came mid-scan and that file stayed off the Media tab until the
/// next pull to refresh. Now a request during a scan is remembered, and one
/// more scan runs when the current one ends. Android twin: the same rule in
/// the Media screen's loader.
struct MediaRescanGate: Equatable {
    private(set) var scanning = false
    private(set) var pending = false

    /// True: start a scan now. False: one is running; it will run again after.
    mutating func request() -> Bool {
        if scanning {
            pending = true
            return false
        }
        scanning = true
        return true
    }

    /// Call when a scan ends. True: scan again (something landed meanwhile).
    mutating func finish() -> Bool {
        if pending {
            pending = false
            return true
        }
        scanning = false
        return false
    }

    /// The scan result should replace the shown list when the files differ,
    /// not only when their number does: one file in and one out is a change.
    static func filesChanged(old: [URL], new: [URL]) -> Bool {
        old.count != new.count || Set(old) != Set(new)
    }
}

/// When Auto-Mirror (`HavenConfig.autoMirrorMedia`) runs by itself: on, and
/// not within `every` of the last run. It lists every server and scans
/// every note, so it runs when the app opens, at most once every few hours.
/// Rule 3: counted from when a run starts, so a relaunch mid-run does not
/// start another one. Android twin: `AutoMirrorRules.due`.
enum AutoMirrorSchedule {
    static let every: TimeInterval = 3 * 60 * 60

    static func isDue(enabled: Bool, lastRun: Date?, now: Date, every: TimeInterval = every) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        // A clock set back doesn't hold it off for good.
        if now < lastRun { return true }
        return now.timeIntervalSince(lastRun) >= every
    }

    /// The later of the last run's start and the last import that finished.
    static func lastRun(started: Date?, finished: Date?) -> Date? {
        [started, finished].compactMap { $0 }.max()
    }
}
