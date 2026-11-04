import CoreGraphics

/// How much of the iPhone/iPad dock a screen still has to clear by hand.
///
/// While the dock's band is safe area on the window's root view controller
/// (`DockInset.Placement.rootBand`, for picture-in-picture), every screen's
/// bottom safe area already includes it. Floating buttons and full-bleed
/// screens that add the dock's height themselves would count it twice and sit
/// a whole dock too high, so they take the band off again here.
enum DockClearance {
    /// The part of the dock already inside the screens' bottom safe area.
    /// Same rule the dock uses to set the root inset (`DockInset`).
    static func band(dockHeight: CGFloat, keyboardUp: Bool) -> CGFloat {
        DockInset.rootBottom(
            placement: DockInset.placement(dockShown: dockHeight > 0, keyboardUp: keyboardUp),
            dockHeight: dockHeight
        )
    }

    /// What is left of `height` once the band is already safe area.
    static func remaining(_ height: CGFloat, band: CGFloat) -> CGFloat {
        max(0, height - band)
    }
}
