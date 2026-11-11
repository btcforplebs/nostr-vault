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

    /// A clip turns the screen sideways by itself only when it is wider than
    /// it is tall. Square and portrait clips stay upright.
    static func turnsSideways(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width > size.height
    }
}
