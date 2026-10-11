import SwiftUI

/// One comment under an article: who, when, what. Opens as a note, where its
/// replies are.
struct ArticleCommentRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    let replies: Int

    var body: some View {
        NoteNavigationLink(note: note) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 24)
                    Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                        .font(.appSystem(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(note.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                let text = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs)
                if !text.characters.isEmpty {
                    Text(text)
                        .font(.appSystem(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if replies > 0 {
                    Label(replies == 1 ? "1 reply" : "\(replies) replies", systemImage: "arrowshape.turn.up.left")
                        .font(.appSystem(size: 12, weight: .medium))
                        .foregroundColor(.havenPurple)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
