import SwiftUI

/// Messages' way in to Requests (people outside your Web of Trust), as a
/// top-right tray button instead of a row at the bottom of the list (Logen,
/// 2026-11-03). No count on it (Logen, 2026-11-04: "it's bothersome"):
/// requests never notify, and they add to no badge anywhere.
struct DMRequestsButton: View {
    /// The requests list is showing (the iPad's left pane): the tray fills in.
    var isActive: Bool = false
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "tray.fill" : "tray")
                .font(.appSystem(size: size, weight: .semibold))
                .foregroundColor(.havenPurple)
        }
        .accessibilityLabel("Requests")
        .help("Requests: messages from people outside your Web of Trust")
    }
}
