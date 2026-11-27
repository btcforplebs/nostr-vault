import Foundation

/// The composer's live preview redraws at most once per window while you type:
/// a throttle, not a debounce. A debounce restarted at every key froze the
/// preview for the whole typing burst (anyone faster than one key per 250 ms
/// saw nothing move until they stopped). Every key re-arms the redraw at the
/// same deadline (the last redraw plus one window), so a burst redraws about
/// every `window` and the last key shows at most one window after it.
enum PreviewThrottle {
    static let window: TimeInterval = 0.15

    /// How long to wait before the next redraw: none when the last one was a
    /// full window ago, else the rest of that window.
    static func wait(lastDrawAt: Date, now: Date, window: TimeInterval = window) -> TimeInterval {
        max(0, lastDrawAt.addingTimeInterval(window).timeIntervalSince(now))
    }
}
