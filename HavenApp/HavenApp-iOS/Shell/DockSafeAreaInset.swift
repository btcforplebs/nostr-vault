import SwiftUI
import UIKit

/// Marks the dock's band (mini player + tab bar) as safe area on the window's
/// root view controller (`additionalSafeAreaInsets.bottom`), so a picture-in-
/// picture window keeps clear of it the way it keeps clear of system bars
/// (RESEARCH/NV_PIP_PLAN.md: PiP avoids the root's bottom safe area, not a
/// SwiftUI `.safeAreaInset`). The dock is then drawn in that band
/// (`iPhoneTabView`), so screens lay out exactly as before. Sheets and
/// full-screen covers are their own view controllers and don't take it.
struct DockSafeAreaInset: UIViewRepresentable {
    let bottom: CGFloat

    func makeUIView(context: Context) -> Marker { Marker(bottom: bottom) }

    func updateUIView(_ marker: Marker, context: Context) {
        marker.bottom = bottom
        marker.apply()
    }

    static func dismantleUIView(_ marker: Marker, coordinator: ()) {
        marker.bottom = 0
        marker.apply()
    }

    final class Marker: UIView {
        var bottom: CGFloat

        init(bottom: CGFloat) {
            self.bottom = bottom
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard let root = window?.rootViewController else { return }
            let value = DockInset.rounded(bottom)
            if root.additionalSafeAreaInsets.bottom != value {
                root.additionalSafeAreaInsets.bottom = value
            }
        }
    }
}
