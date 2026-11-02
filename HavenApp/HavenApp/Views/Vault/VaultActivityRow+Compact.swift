import SwiftUI

// MARK: - One-line row (iPad's Live Vault column)

extension VaultActivityRow {
    /// The line on one fixed-height row: icon, the newest face, who did what,
    /// and their words or your post, cut to one line. Fixed height so rows
    /// never move as text or pictures load.
    var compactBody: some View {
        HStack(spacing: 10) {
            badge
            if let first = line.actors.first {
                AvatarView(url: nostrService.profiles[first]?.pictureURL, pubkey: first, size: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                (Text(who).fontWeight(.semibold) + Text(" " + verb))
                    .font(.appSystem(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(readablePreview.isEmpty ? timeAgo : readablePreview)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isUnread {
                Circle()
                    .fill(Color.havenPurple)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: LiveVaultLayout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.havenPurple.opacity(isUnread ? 0.06 : 0))
        .contentShape(Rectangle())
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "New" : "")
    }
}

enum LiveVaultLayout {
    /// Every row's height, so drawn rows keep their place.
    static let rowHeight: CGFloat = 58
    static let openWidth: CGFloat = 320
    static let foldedWidth: CGFloat = 56
}
