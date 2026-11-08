import Foundation

/// The band behind the iPhone feed's top pills (Logen 2026-11-08). The
/// system bar's fill and its scroll-edge effect are both off on the feed
/// (#1651: the effect drew a dark band), so posts scrolled under the clock
/// with nothing behind it. This band is the page colour, solid behind the
/// clock, fading to clear under the pills: Android's GlassScaffold scrim,
/// same stops. Shown on every feed type but Reels, whose video runs edge to
/// edge (Android skips Reels too).
///
/// Pure Foundation so MediaLogicTests can test it; the view maps the stops
/// to a LinearGradient.
enum FeedTopFade {
    struct Stop: Equatable {
        /// 0 = top of the band, 1 = its bottom.
        let location: Double
        /// Of the page colour.
        let opacity: Double
    }

    /// The band runs from the screen's top edge to the bottom of the pill
    /// row (`total`, the feed's top safe area: clock + bar). The clock's part
    /// (`statusBar`) stays solid; below it the band holds 0.7 at 70% of the
    /// way down and is clear at the bottom. Empty when there is no band.
    static func stops(statusBar: Double, total: Double) -> [Stop] {
        guard total > 0 else { return [] }
        let solid = min(max(statusBar / total, 0), 0.9)
        return [
            Stop(location: 0, opacity: 1),
            Stop(location: solid, opacity: 1),
            Stop(location: solid + (1 - solid) * 0.7, opacity: 0.7),
            Stop(location: 1, opacity: 0),
        ]
    }

    /// Whether the feed shows the band: the iPhone's bar in the system
    /// navigation bar only (the iPad's floating bar has its own edge), and
    /// not over Reels.
    static func shows(isReels: Bool, floatingBar: Bool) -> Bool {
        !isReels && !floatingBar
    }
}
