import CoreGraphics

/// How many full-screen viewers are open that let the phone turn sideways.
///
/// The phone app is held upright everywhere else. Each viewer opens and
/// closes its own slot, so a viewer opened over another one (a photo opened
/// from live full screen, or the next page of a note's media) cannot lock
/// the screen upright while the one under it is still showing.
struct LandscapeCount: Equatable {
    private(set) var open = 0

    /// Landscape is allowed while any viewer is open.
    var allowsLandscape: Bool { open > 0 }

    mutating func opened() { open += 1 }

    /// Returns `true` when the last viewer closed: the screen should go upright.
    @discardableResult
    mutating func closed() -> Bool {
        guard open > 0 else { return false }
        open -= 1
        return open == 0
    }

    /// Whether a viewer page holds a slot: only a clip, only while it is the
    /// page on screen, and not once the viewer has started to close.
    /// Photos never needed one: holding it let iOS turn a photo to however
    /// the phone was lying, and a clip on the next page turned the photo
    /// you were looking at.
    static func pageHolds(isClip: Bool, isOnScreen: Bool, isClosing: Bool) -> Bool {
        isClip && isOnScreen && !isClosing
    }
}
