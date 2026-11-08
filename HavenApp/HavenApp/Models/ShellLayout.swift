import CoreGraphics

/// Which shell the iOS app draws, from the device and the window's size.
///
/// - `phone`: the bottom dock (every iPhone, closed or not foldable).
/// - `padUpright`: an iPad (regular width) upright: notes beside the list, bottom dock.
/// - `padLandscape`: a slim rail on the left, the app, "Your space" on the right.
/// - `fold`: an open folding iPhone (Logen, 2026-11-08): "Your space" on the
///   left half, the app on the right half with the rail on its far edge, and
///   a plain gutter on the fold so nothing sits on the crease.
enum ShellLayout: Equatable {
    case phone
    case padUpright
    case padLandscape
    case fold

    /// No closed iPhone has a short side this wide (a Pro Max is 440 pt); an
    /// open folding one does, in either orientation. Measured on the window,
    /// so it does not depend on the size class the phone reports.
    static let foldMinShortSide: CGFloat = 600

    /// The gutter left empty over the fold, in points.
    static let foldGutter: CGFloat = 20

    static func pick(isPhone: Bool, regularWidth: Bool, window: CGSize, forceFold: Bool = false) -> ShellLayout {
        let shortSide = min(window.width, window.height)
        if forceFold || (isPhone && shortSide >= foldMinShortSide) { return .fold }
        guard regularWidth else { return .phone }
        return window.width > window.height ? .padLandscape : .padUpright
    }

    /// Lists sit in a note split (notes open over the list, ‹ Back).
    var usesNoteSplit: Bool { self != .phone }

    /// The tab items run down a side rail instead of the bottom dock.
    var hasSideRail: Bool { self == .padLandscape || self == .fold }

    /// The width of the left half in a fold layout, so that half ends half a
    /// gutter before the middle of the screen. `windowWidth` is the whole
    /// screen; `leadingInset` is the safe area already taken on the left.
    static func foldLeftWidth(windowWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        max(0, (windowWidth - foldGutter) / 2 - leadingInset)
    }
}
