import SwiftUI

/// How far the iPhone chrome (bottom tab bar + feed top bar) is folded away,
/// driven by the finger rather than by a timed animation.
///
/// `progress` follows the scroll 1:1 while the user drags, so a half-drag
/// leaves the bars half-folded and reversing the drag brings them straight
/// back. On release it settles to whichever end is nearer, or to the end a
/// fling is heading for. Both bars read this one value and settle on one
/// `Motion.chrome` spring, so they can never drift apart.
///
/// `@Observable`, not a `FeedService` property: `progress` changes every
/// frame of a drag, and only the two bars should re-render for it. A
/// `@Published` write would invalidate every view observing `FeedService`.
/// Views that need a yes/no (the feed top bar's layout) read `isFolded`,
/// which only changes at the ends.
@Observable
@MainActor
final class ChromeCollapse {
    static let shared = ChromeCollapse()

    /// 0 = fully shown, 1 = fully folded.
    private(set) var progress: CGFloat = 0

    /// True only once the bars are completely folded; false again the moment
    /// they start coming back, so the top bar's pills can fade in with the
    /// finger rather than appearing after it.
    private(set) var isFolded = false

    /// Scroll distance that folds the bars completely — about one bar height,
    /// so the chrome moves at the same speed as the content under it.
    static let distance: CGFloat = 60

    /// A fling faster than this (points/second) commits to its direction
    /// immediately instead of dragging the bars along with the deceleration.
    static let flingVelocity: CGFloat = 400

    private init() {}

    /// Opacity of what the fold hides: gone by 60%.
    static func fadeOut(_ p: CGFloat) -> Double { Double(max(0, 1 - p / 0.6)) }
    /// Opacity of what the fold reveals: starts at 40%. The two curves never
    /// sit at similar strengths, so outgoing and incoming controls do not
    /// read as stacked on top of each other.
    static func fadeIn(_ p: CGFloat) -> Double { Double(max(0, (p - 0.4) / 0.6)) }

    /// Sets progress directly — used while the finger (or its fling) is
    /// driving the scroll.
    func track(_ value: CGFloat) {
        set(value)
    }

    /// Animates to a resting state.
    func settle(to value: CGFloat) {
        guard value != progress else { return }
        withAnimation(Motion.chrome) { set(value) }
    }

    /// Brings the bars fully back: tab switch, tapping the folded avatar,
    /// account switch.
    func reset() {
        settle(to: 0)
    }

    private func set(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        if clamped != progress { progress = clamped }
        let folded = clamped >= 1
        if folded != isFolded { isFolded = folded }
    }
}
