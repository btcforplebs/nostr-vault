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
        /// No dock (typing on Search, the iPad landscape rail).
        case none
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
