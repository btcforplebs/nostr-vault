import SwiftUI

/// Fades and slightly shrinks its content with the chrome fold. Its own view
/// so that reading the per-frame `progress` re-renders only this wrapper,
/// not the screen that builds the content.
struct ChromeFold<Content: View>: View {
    var anchor: UnitPoint = .center
    /// `true` for content that appears as the bars fold (the lone layout
    /// button), rather than disappears.
    var inverted = false
    var isEnabled = true
    @ViewBuilder var content: Content

    var body: some View {
        let p = isEnabled ? ChromeCollapse.shared.progress : 0
        let visible = inverted ? ChromeCollapse.fadeIn(p) : ChromeCollapse.fadeOut(p)
        content
            .opacity(visible)
            .scaleEffect(0.85 + 0.15 * visible, anchor: anchor)
            .allowsHitTesting(visible > 0.5)
            .accessibilityHidden(visible <= 0.5)
    }
}
