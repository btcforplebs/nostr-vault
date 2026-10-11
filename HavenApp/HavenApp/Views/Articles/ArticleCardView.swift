import SwiftUI

// MARK: - Card

/// One row in the Articles feed: hero image, title, summary, author and
/// reading time. Renders entirely from tags plus a truncated body preview, so
/// it never needs the full article text.
struct ArticleCardView: View {
    let note: FeedNote
    let profile: FeedProfile?
    var onAuthorTap: ((String) -> Void)? = nil

    private var metadata: LongFormMetadata { note.longFormMetadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageURL = metadata.imageURL {
                RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 800, height: 400))
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(note.longFormDisplayTitle)
                    .font(.appSystem(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if let preview = previewText, !preview.isEmpty {
                    Text(preview)
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                if !metadata.topics.isEmpty {
                    topicChips
                }

                HStack(spacing: 8) {
                    AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 22)
                        .onTapGesture { onAuthorTap?(note.pubkey) }

                    Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text(note.longFormDisplayDate, format: .dateTime.month(.abbreviated).day().year())
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)

                    if let gated = note.gatedArticle {
                        Text("·")
                            .foregroundColor(.secondary)
                        Label("\(gated.priceSats) sats", systemImage: "lock.fill")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    } else if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("\(minutes) min read")
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// The author's own `summary` tag when they wrote one, otherwise the top of
    /// the body with markdown syntax stripped.
    private var previewText: String? {
        if let summary = metadata.summary { return summary }
        let body = note.gatedArticle == nil ? note.content : GatedArticleTeaser.strip(note.content)
        let plain = MarkdownParser.plainText(body, limit: 200)
        return plain.isEmpty ? nil : plain
    }

    private var topicChips: some View {
        // A handful of topics keeps the card one line; long-form authors
        // sometimes attach a dozen.
        HStack(spacing: 6) {
            ForEach(metadata.topics.prefix(3), id: \.self) { topic in
                Text(topic)
                    .font(.appSystem(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.havenPurplePale)
                    .foregroundColor(.havenPurple)
                    .clipShape(Capsule())
            }
        }
    }
}
