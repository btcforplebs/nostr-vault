import CoreGraphics

/// The one line a tapped post's top lands on, in note detail and in the feed:
/// 20 pt under the top bar's buttons. Both screens' scroll views start at the
/// bar's edge, 10 pt below the buttons, so the line is `gap` under that edge.
/// One value on every device, orientation and window size, and not scaled
/// with Dynamic Type: larger text makes a post taller, not its top lower.
enum TapLandingLine {
    /// Points from the scroll view's top edge to the line.
    static let gap: CGFloat = 10

    /// `scrollTo` anchor y that puts a zero-height marker on the line. With
    /// a zero-height target the post's own height plays no part, so a short
    /// reply and a long one land in the same place.
    static func anchorY(viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > gap else { return 0 }
        return gap / viewportHeight
    }

    /// Room under the last row while a post is open, so one near the end of
    /// the list can still scroll up to the line: everything from the line to
    /// the bottom edge.
    static func bottomRoom(viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight - gap)
    }
}
