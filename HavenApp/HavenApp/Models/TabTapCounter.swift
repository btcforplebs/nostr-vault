import Foundation

/// Counts quick taps on one tab-bar button, so the shell can tell a re-tap
/// from a triple-tap (Logen, 2026-11-19). A tap within `window` of the last
/// one on the same tab continues the run; anything else starts a new one.
/// The third tap of a run is reported as 3 and ends it, so a fourth starts
/// over at 1 rather than firing the triple-tap again.
struct TabTapCounter {
    /// Longest gap between taps that still counts as one run.
    static let window: TimeInterval = 0.45

    private var tab: Int?
    private var count = 0
    private var last: Date?

    /// Records a tap on `tab` and returns its place in the run: 1, 2 or 3.
    mutating func register(tab: Int, at now: Date = Date()) -> Int {
        if tab == self.tab, let last, now.timeIntervalSince(last) <= Self.window, count > 0 {
            count += 1
        } else {
            count = 1
        }
        self.tab = tab
        last = now
        let place = count
        if place >= 3 { count = 0 }
        return place
    }
}
