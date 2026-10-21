import SwiftUI

/// The floating "New Posts" button's fold. It leaves with the bars as you
/// scroll down, rising back up under the top bar, and returns with them;
/// folded, the small pill in the top bar's row stands in for it.
/// Its own view for the same reason as `ChromeFold`.
struct NewPostsFold<Content: View>: View {
    var isEnabled = true
    @ViewBuilder var content: Content

    var body: some View {
        let p = isEnabled ? ChromeCollapse.shared.progress : 0
        let visible = ChromeCollapse.fadeOut(p)
        content
            .opacity(visible)
            .scaleEffect(0.85 + 0.15 * visible, anchor: .top)
            .offset(y: -16 * (1 - visible))
            .allowsHitTesting(visible > 0.5)
            .accessibilityHidden(visible <= 0.5)
    }
}
