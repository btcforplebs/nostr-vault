import SwiftUI

/// Messages' way in to Requests (people outside your Web of Trust), as a
/// top-right tray button with a count badge instead of a row at the bottom of
/// the list (Logen, 2026-11-03). Their messages never notify, so the count is
/// how many conversations wait there, not unread messages.
struct DMRequestsButton: View {
    let count: Int
    /// The requests list is showing (the iPad's left pane): the tray fills in.
    var isActive: Bool = false
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "tray.fill" : "tray")
                .font(.appSystem(size: size, weight: .semibold))
                .foregroundColor(.havenPurple)
                .modifier(RequestsBadge(count: count))
        }
        .accessibilityLabel("Requests")
        .accessibilityValue(count == 1 ? "1 conversation" : "\(count) conversations")
        .help("Requests: messages from people outside your Web of Trust")
    }
}

/// The count over the tray, the composer's draft badge (draftCountBadge); none at 0.
private struct RequestsBadge: ViewModifier {
    let count: Int

    func body(content: Content) -> some View {
        if count > 0 {
            content.draftCountBadge(count, ringColor: .platformWindowBackground)
        } else {
            content
        }
    }
}
