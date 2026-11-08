import CoreGraphics

/// Which shell the iOS app draws, from the device and the window's size.
///
/// - `phone`: the bottom dock (every iPhone, and the open iPhone Duo upright).
/// - `padUpright`: an iPad (regular width) upright: notes beside the list, bottom dock.
/// - `padLandscape`: a slim rail on the left, the app, "Your space" on the right.
/// - `duoClosed`: the iPhone Duo folded shut (Logen, 2026-11-08): the app as
///   on any iPhone, top navigation and all, with the dock as a rail down the
///   right edge instead of along the bottom.
/// - `fold`: the iPhone Duo open on its side: "Your space" on the left half,
///   the app on the right half with the rail on its far edge, and a plain
///   gutter on the fold so nothing sits on the crease.
///
/// The Duo shells never put lists in a note split, so folding, unfolding and
/// turning the phone keep the same view tree under the app
/// (`iPhoneTabView.tabs`), and with it the tab, the scroll position and any
/// open sheet.
enum ShellLayout: Equatable {
    case phone
    case padUpright
    case padLandscape
    case duoClosed
    case fold

    /// No other iPhone has a short side this wide (a Pro Max is 440 pt); the
    /// iPhone Duo's outer screen is 466 x 678 pt.
    static let duoClosedMinShortSide: CGFloat = 460

    /// The iPhone Duo open is 669 x 951 pt. Measured on the window, so it
    /// does not depend on the size class the phone reports.
    static let foldMinShortSide: CGFloat = 600

    /// The gutter left empty over the fold, in points.
    static let foldGutter: CGFloat = 20

    static func pick(isPhone: Bool, regularWidth: Bool, window: CGSize) -> ShellLayout {
        let shortSide = min(window.width, window.height)
        let wide = window.width > window.height
        if isPhone && shortSide >= foldMinShortSide { return wide ? .fold : .phone }
        if isPhone && shortSide >= duoClosedMinShortSide { return .duoClosed }
        guard regularWidth else { return .phone }
        return wide ? .padLandscape : .padUpright
    }

    /// Lists sit in a note split (notes open over the list, ‹ Back). iPads only.
    var usesNoteSplit: Bool { self == .padUpright || self == .padLandscape }

    /// The tab items run down a side rail instead of the bottom dock.
    var hasSideRail: Bool { self == .padLandscape || self == .fold || self == .duoClosed }

    /// That rail is on the window's right edge (the iPhone Duo, closed or open).
    var railOnRight: Bool { self == .fold || self == .duoClosed }

    /// The width of the left half in a fold layout, so that half ends half a
    /// gutter before the middle of the screen. `windowWidth` is the whole
    /// screen; `leadingInset` is the safe area already taken on the left.
    static func foldLeftWidth(windowWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        max(0, (windowWidth - foldGutter) / 2 - leadingInset)
    }
}
