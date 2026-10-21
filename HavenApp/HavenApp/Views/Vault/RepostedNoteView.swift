import SwiftUI

struct RepostedNoteView: View {
    let inner: NostrEvent
    @EnvironmentObject var nostrService: NostrService

    private var innerDisplayName: String {
        if let profile = nostrService.profiles[inner.pubkey] {
            return profile.bestName
        }
        return inner.pubkey.prefix(8) + "..." + inner.pubkey.suffix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inner note author header
            HStack(spacing: 8) {
                AvatarView(
                    url: nostrService.profiles[inner.pubkey]?.pictureURL,
                    pubkey: inner.pubkey,
                    size: 28
                )
                .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

                Text(innerDisplayName)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .lineLimit(1)

                if inner.isFromNostrVault {
                    NostrVaultBadge(size: 10)
                }

                Spacer()

                Text(timeAgo(from: inner.createdAtDate))
                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Inner note content
            let urls = inner.mediaURLs
            let links = LinkCards.shown(inner.linkURLs)
            let content = inner.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                Text(NostrContentFormatter.format(content, mediaURLs: urls + links))
                    .font(.appSystem(size: 14, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .lineSpacing(2)
                    .lineLimit(nil)
            }

            // Media previews
            if !urls.isEmpty {
                if urls.count == 1 {
                    FeedMediaView(url: urls[0], maxHeight: 250, portraitMaxHeight: 350, isThumbnail: false)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    MediaPagerView(items: Array(urls.prefix(4))) { url in
                        FeedMediaView(url: url, maxHeight: 250, portraitMaxHeight: 350, isThumbnail: false)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            #if os(iOS)
                            .transition(.opacity.animation(Motion.media))
                            #endif
                    }
                    .frame(height: 250)
                }
            }

            // Link previews, one per link — the text no longer shows them.
            ForEach(links, id: \.self) { url in
                LinkPreviewCard(url: url)
            }

            // Quoted notes and articles
            QuotedEventsView(identifiers: inner.quotedEventIds, content: inner.content)
        }
        .padding(10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5)
        )
        .onAppear {
            if nostrService.profiles[inner.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [inner.pubkey])
            }
        }
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
