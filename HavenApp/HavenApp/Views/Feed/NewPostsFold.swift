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

/// New posts going in at the top of the feed: each one comes down from
/// behind the top bar (`.move(edge: .top)` slides it from just above its own
/// slot) and the feed under it is pushed down by the same spring.
enum NewPostsDropIn {
    /// Rows while a drop-in is running. Removal stays the plain fade.
    static var transition: AnyTransition {
        Motion.isReduced
            ? .opacity
            : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    /// How long a drop-in stays armed: covers the threaded feed's regroup,
    /// which lands a moment after the posts go in.
    static let window: Double = 0.8
}
