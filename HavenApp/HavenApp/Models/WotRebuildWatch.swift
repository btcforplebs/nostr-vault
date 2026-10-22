import Foundation

/// After a follow or unfollow, when to look at `wot_cache.json` again.
///
/// The relay rebuilds the web once a new follow list has sat for a minute, and
/// a depth-3 pass takes minutes more. The app re-read the file only on a mode
/// switch or reconnect, so after an unfollow everyone only that follow brought
/// in stayed in Global until something else happened to reload it. The watch
/// looks every `interval` and loads the file the moment the relay rewrites it,
/// then stops; it gives up after `window`.
struct WotRebuildWatch {
    static let interval: TimeInterval = 20
    static let window: TimeInterval = 15 * 60

    enum Step: Equatable { case wait, reload, stop }

    let startedAt: Date
    /// The cache file's modification date when the list was published.
    let stampAtStart: Date?

    func step(stamp: Date?, now: Date) -> Step {
        if stamp != stampAtStart, stamp != nil { return .reload }
        return now.timeIntervalSince(startedAt) >= Self.window ? .stop : .wait
    }
}
