import SwiftUI

/// "N notes from outside your web" at the top of a feed: replies and mentions
/// to you from people outside your web, which the gate keeps out of the feed
/// (`FeedService.feedOutsideMentions`). One tap opens them where they live,
/// Vault › Outside your web. Styled like the thread page's fold row
/// (`NoteDetailView.outsideWebButton`).
struct FeedOutsideRow: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text(TrustGate.outsideLabel(count: count, noun: "note"))
                    .font(.appSystem(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.appSystem(size: 11, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens them in the Vault")
        .accessibilityIdentifier("feed.outsideYourWeb")
    }

    /// Opens Vault › Outside your web: the Vault tab first, then the list
    /// once the tab exists (`RelayFocus`, type "outside").
    @MainActor static func openVaultOutside() {
        NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
        RelayFocus.request(type: "outside", eventId: "")
    }
}
