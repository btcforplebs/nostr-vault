import SwiftUI

// MARK: - Inline body (long-form inside the notes feed)

/// A long-form event drawn inside a normal feed row.
///
/// The notes feed carries kinds 1, 6 and 30023, but the row drew every one of
/// them as `Text(content)` — so an article arrived as its whole markdown body,
/// unbounded, with `##` and `---` intact and its title (a tag, not body text)
/// missing entirely.
///
/// Deliberately not `ArticleCardView`: the feed row already draws the author,
/// the timestamp and the action bar, and the card would draw a second author
/// line inside the first one.
struct ArticleInlineBody: View {
    let note: FeedNote
    /// Focused rows are the note detail's own header row, where the reader is
    /// what the user came for. In the feed it stays a preview.
    var isFocused: Bool = false
    var onImageTap: ((URL) -> Void)? = nil

    private var metadata: LongFormMetadata { note.longFormMetadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageURL = metadata.imageURL {
                RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 800, height: 400))
                    .frame(height: isFocused ? 180 : 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Text(note.longFormDisplayTitle)
                .font(.appSystem(size: isFocused ? 22 : 18, weight: .bold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(isFocused ? nil : 3)

            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.appSystem(size: 10, weight: .semibold))
                Text(String(localized: "feed.note.longForm"))
                    .font(.appSystem(size: 11, weight: .semibold))
                if let gated = note.gatedArticle {
                    Text("· 🔒 \(gated.priceSats) sats")
                        .font(.appSystem(size: 11, weight: .semibold))
                } else if let minutes = LongFormMetadata.readingTimeMinutes(for: note.content) {
                    Text("· \(minutes) min read")
                        .font(.appSystem(size: 11))
                }
            }
            .foregroundColor(.havenPurple)
            .accessibilityElement(children: .combine)

            if isFocused {
                if let summary = metadata.summary {
                    Text(summary)
                        .font(.appSystem(size: 15))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                if let gated = note.gatedArticle {
                    GatedArticleBody(note: note, gated: gated, onImageTap: onImageTap)
                } else {
                    MarkdownBodyView(markdown: note.content, onImageTap: onImageTap)
                }
            } else if let preview = previewText, !preview.isEmpty {
                Text(preview)
                    .font(.appSystem(size: 15))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(.top, 4)
    }

    /// The author's `summary` tag when they wrote one, otherwise the top of the
    /// body with markdown syntax stripped — never the raw markdown.
    private var previewText: String? {
        if let summary = metadata.summary { return summary }
        let body = note.gatedArticle == nil ? note.content : GatedArticleTeaser.strip(note.content)
        let plain = MarkdownParser.plainText(body, limit: 200)
        return plain.isEmpty ? nil : plain
    }
}
