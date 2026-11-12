import CoreGraphics

/// Which side Your space and the dock's rail take in each shell.
///
/// Logen, 2026-11-12: the iPad in landscape is mirrored. Your space goes on
/// the left, built like the open iPhone Duo's half (its icon rail on the
/// screen's left edge, the panels sliding shut to it without reflow, and a
/// widget taken off Your space keeping its rail icon), and the dock's rail
/// goes on the right edge. The iPad keeps one column for Your space, not
/// the Duo's half of the screen.
extension ShellLayout {
    /// Your space sits left of the app: the open Duo and the iPad in landscape.
    var spaceOnLeft: Bool { self == .fold || self == .padLandscape }

    /// The dock's rail is on the window's right edge: every shell with a side rail.
    var dockRailOnRight: Bool { hasSideRail }

    /// The iPad's Your space column: its panels plus its rail, or only the
    /// rail while it is folded.
    static func padSpaceWidth(folded: Bool, panelsWidth: CGFloat, railWidth: CGFloat) -> CGFloat {
        folded ? railWidth : panelsWidth + railWidth
    }
}
