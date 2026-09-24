import SwiftUI

struct QuotedNoteView: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let profile = nostrService.profiles[note.pubkey]
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 18)
                
                Text(profile?.bestName ?? "Someone")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))

                Spacer()

                Text(relativeTime(note.createdAt))
                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            if isLongForm {
                articleBody
            } else {
                noteBody
            }
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            // The fill step alone (tertiary sitting on the note card's secondary)
            // is 1.10-1.22:1 — a seam, not a boundary — and the old purple accent
            // stroke it wore instead only reached 1.17-1.55:1. `borderStrong` is
            // the ramp's token for exactly this: a border that is the only real
            // cue a card is nested inside another. 3.16-3.22:1 here.
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderStrong, lineWidth: 1)
        )
    }
    
    /// A NIP-23 article. Its `content` is a whole markdown document, so showing
    /// the first three lines of it shows `##` markup rather than the article —
    /// the headline, cover and summary live in tags instead.
    private var isLongForm: Bool { note.kind == 30023 }

    @ViewBuilder
    private var articleBody: some View {
        HStack(alignment: .top, spacing: 10) {
            if let imageURL = note.longFormMetadata.imageURL {
                CachedAsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.platformTertiaryGroupedBackground
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Article")
                    .font(.appSystem(size: 10, weight: .semibold))
                    .foregroundColor(.havenPurple.opacity(0.8))

                Text(note.longFormDisplayTitle)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let summary = articleSummary {
                    Text(summary)
                        .font(.appSystem(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var articleSummary: String? {
        if let summary = note.longFormMetadata.summary { return summary }
        let plain = MarkdownParser.plainText(note.content, limit: 200)
        return plain.isEmpty ? nil : plain
    }

    @ViewBuilder
    private var noteBody: some View {
        let formattedContent = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs)
        if !formattedContent.characters.isEmpty {
            Text(formattedContent)
                .font(.appSystem(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }

        if !note.mediaURLs.isEmpty {
            FeedMediaView(
                url: note.mediaURLs[0],
                maxHeight: 180,
                portraitMaxHeight: 220,
                isThumbnail: false
            )
            .allowsHitTesting(false)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                ? "MMM d" : "MMM d, yyyy"
            return fmt.string(from: date)
        }
    }
}
