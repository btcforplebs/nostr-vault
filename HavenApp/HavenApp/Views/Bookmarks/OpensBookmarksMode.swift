import SwiftUI

/// Switches the Vault to its Bookmarks mode when VaultMode.bookmarks is
/// picked (`.havenOpenRelayBookmarks`). A modifier rather than one more
/// `onReceive` in VaultView's chain, which is at the type checker's limit.
struct OpensBookmarksMode: ViewModifier {
    @Binding var viewMode: ViewMode

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayBookmarks)) { _ in
            withAnimation(Motion.toggle) { viewMode = .bookmarks }
        }
    }
}

/// Runs `action` when VaultMode.bookmarks is picked: the Mac window uses it to
/// bring up its Vault tab first. A modifier for the same type-checker reason.
struct OnOpenBookmarksMode: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayBookmarks)) { _ in action() }
    }
}
