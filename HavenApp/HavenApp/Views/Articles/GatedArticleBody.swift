import SwiftUI

// MARK: - Gated (locked) body

/// The body of a gated article: its teaser and a lock card, or the decrypted
/// article when this reader already unlocked it. The app never pays for or
/// asks to unlock an article. See `GatedArticle`.
struct GatedArticleBody: View {
    let note: FeedNote
    let gated: GatedArticle
    var onImageTap: ((URL) -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService

    var body: some View {
        if let markdown = GatedArticleService.shared.unlockedBody(note: note, gated: gated) {
            MarkdownBodyView(markdown: markdown, onImageTap: onImageTap)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                let teaser = GatedArticleTeaser.strip(note.content)
                if !teaser.isEmpty, teaser != note.longFormMetadata.summary {
                    MarkdownBodyView(markdown: teaser, onImageTap: onImageTap)
                }
                lockCard
            }
        }
    }

    private var authorName: String {
        nostrService.profiles[note.pubkey]?.bestName ?? "the author"
    }

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Locked article")
                    .font(.appSystem(size: 16, weight: .bold))
            }

            Text(GatedLockCopy.status(author: authorName))
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.35), lineWidth: 1)
        )
    }
}
