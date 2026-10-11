import SwiftUI

/// One person's highlight: who, the passage, and their comment if any.
struct HighlightRow: View {
    let highlight: ArticleHighlight
    /// Opens a reply (a NIP-22 comment) to this highlight.
    var onComment: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if let onComment {
                Button(action: onComment) {
                    Label("Comment", systemImage: "bubble.left")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 11)
            }
        }
    }

    private var content: some View {
        let profile = nostrService.profiles[highlight.pubkey]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: highlight.pubkey, size: 22)
                Text(profile?.bestName ?? "npub…" + String(highlight.pubkey.suffix(6)))
                    .font(.appSystem(size: 13, weight: .semibold))
                Text(highlight.createdAt, style: .relative)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.yellow.opacity(0.8)).frame(width: 3)
                Text(highlight.passage)
                    .font(.appSystem(size: 14))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let comment = highlight.comment {
                Text(comment)
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
