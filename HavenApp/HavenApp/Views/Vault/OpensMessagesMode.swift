import SwiftUI

/// Switches the Vault to its Messages page when one is asked for
/// (`DMInboxRoute`). A modifier rather than one more `onReceive` in
/// VaultView's chain, which is at the type checker's limit.
struct OpensMessagesMode: ViewModifier {
    @Binding var viewMode: ViewMode
    @ObservedObject private var route = DMInboxRoute.shared

    func body(content: Content) -> some View {
        // Initial too: a request made before this Vault was built (a cold
        // start from a notification, the Mac tab not open yet) is taken here.
        content.onChange(of: route.request, initial: true) { _, _ in
            guard route.takeRequest() else { return }
            withAnimation(Motion.toggle) { viewMode = .messages }
        }
    }
}
