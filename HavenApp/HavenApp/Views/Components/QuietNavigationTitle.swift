import SwiftUI

extension View {
    /// Keeps `title` as the screen's name for VoiceOver, the back button and
    /// the app switcher, but draws no title text in the iPhone/iPad bar, so the
    /// bar's buttons get its room instead of running into it (Logen,
    /// 2026-11-03). macOS keeps its window title.
    func quietNavigationTitle(_ title: String) -> some View {
        modifier(QuietNavigationTitle(title: title))
    }
}

private struct QuietNavigationTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .toolbar {
                // The bar draws the principal item in place of the title. A
                // zero-size element still reads the title as the header.
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel(title)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            #endif
    }
}
