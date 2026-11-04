import Foundation

/// Waiting out the Go relay's last stopped cycle before touching its
/// databases again (backup, restore). Pure, so the loop is tested without Go.
/// Twin of Android `RelayDrainState`.
enum RelayDrainWait {
    /// Android RelayDrainState.MAX_WAIT_MS: a backgrounded cycle's stragglers
    /// were seen draining for about two minutes (2026-11-04 sim, 12:34:02 to
    /// 12:35:55).
    static let maxWait: TimeInterval = 180
    static let pollNanos: UInt64 = 500_000_000

    /// Polls `isDraining` until it says no (true) or `maxWait` passes (false).
    static func wait(maxWait: TimeInterval, pollNanos: UInt64 = pollNanos, now: () -> Date = Date.init,
                     isDraining: () -> Bool, sleep: (UInt64) async -> Void) async -> Bool {
        let deadline = now().addingTimeInterval(maxWait)
        while isDraining() {
            guard now() < deadline else { return false }
            await sleep(pollNanos)
        }
        return true
    }
}
