import CoreGraphics

/// How the iPhone/iPad dock (mini player + tab bar) is laid out (RESEARCH/NV_PIP_PLAN.md).
/// Normally its band is safe area on the window's root view controller, so a
/// picture-in-picture window keeps clear of it, and the dock is drawn in that
/// band. While the keyboard is up the dock rides above the keyboard as a
/// SwiftUI inset instead (the root's safe area doesn't follow the keyboard).
enum DockInset {
    enum Placement: Equatable {
        /// Root safe area = the dock's height; the dock is drawn in that band.
        case rootBand
        /// Today's SwiftUI `.safeAreaInset`, above the keyboard.
        case swiftUIInset
        /// No dock (typing, the iPad landscape rail).
        case none
    }

    /// Whether the dock (tab bar + mini player) is drawn at all. Never while
    /// the keyboard is up, on any tab or pushed page: it covered the message
    /// box of a DM thread (a Vault page since 2026-11-03, no longer a sheet)
    /// and Search's results. Never beside the iPad landscape rail.
    static func shown(keyboardUp: Bool, sideRail: Bool) -> Bool {
        !keyboardUp && !sideRail
    }

    static func placement(dockShown: Bool, keyboardUp: Bool) -> Placement {
        guard dockShown else { return .none }
        return keyboardUp ? .swiftUIInset : .rootBand
    }

    /// What the root view controller's `additionalSafeAreaInsets.bottom` should be.
    static func rootBottom(placement: Placement, dockHeight: CGFloat) -> CGFloat {
        placement == .rootBand ? rounded(dockHeight) : 0
    }

    /// Whole points, so a sub-point wobble in the measured height doesn't
    /// re-lay out the whole app.
    static func rounded(_ value: CGFloat) -> CGFloat {
        max(0, value.rounded())
    }
}
