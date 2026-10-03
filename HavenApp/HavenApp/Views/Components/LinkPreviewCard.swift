import SwiftUI

/// A rich link preview card that fetches and displays OpenGraph metadata.
/// Matches the visual style of QuotedNoteView for consistency.
struct LinkPreviewCard: View {
    let url: URL

    @State private var metadata: LinkPreviewMetadata?
    @State private var isLoading = true

    var body: some View {
        // A Wavlake song plays right here instead of opening a web page.
        if let trackId = WavlakeLink.trackId(from: url) {
            WavlakeTrackCard(trackId: trackId)
        } else {
            preview
        }
    }

    private var preview: some View {
        Group {
            if let metadata = metadata, metadata.title != nil {
                cardContent(metadata)
            } else if isLoading {
                shimmerPlaceholder
            } else {
                // Note text no longer carries the URL, so a site with no
                // preview still needs a card or the link would vanish.
                fallbackCard
            }
        }
        // Keyed on the URL, not on appearance: SwiftUI reuses a view's state
        // when it reuses its identity, and a card that only ever loaded once
        // would keep showing the first link's preview if its row were ever
        // handed a second URL.
        .task(id: url) { await loadMetadata() }
    }

    // MARK: - Card Content

    @ViewBuilder
    private func cardContent(_ meta: LinkPreviewMetadata) -> some View {
        Button {
            PlatformURL.open(url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // OG image thumbnail
                if let imageURL = meta.imageURL {
                    ogImageView(imageURL)
                }

                // Text content
                VStack(alignment: .leading, spacing: 3) {
                    // Site name
                    if let siteName = meta.siteName, !siteName.isEmpty {
                        Text(siteName)
                            .font(.appSystem(size: 10, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }

                    // Title
                    if let title = meta.title {
                        Text(title)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    // Description
                    if let desc = meta.description, !desc.isEmpty {
                        Text(desc)
                            .font(.appSystem(size: 12, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    // Domain
                    Text(displayDomain)
                        .font(.appSystem(size: 10, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.platformTertiaryGroupedBackground)
            .cornerRadius(8)
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
    }

    /// The domain alone, in the same chrome as a full card.
    private var fallbackCard: some View {
        Button {
            PlatformURL.open(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(displayDomain)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.appSystem(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(10)
            .background(Color.platformTertiaryGroupedBackground)
            .cornerRadius(8)
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Link to \(displayDomain)"))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            // Embedded in a note, so it tracks QuotedNoteView — its
            // direct peer — rather than sitting fainter than the card
            // it lives inside.
            .stroke(
                Color.havenPurple.opacity(ConfigService.shared.config.useOLED ? 0.30 : 0.15),
                lineWidth: ConfigService.shared.config.useOLED ? 1.2 : 1
            )
    }

    // MARK: - OG Image

    private func ogImageView(_ imageURL: URL) -> some View {
        CachedAsyncImage(url: imageURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.platformTertiaryGroupedBackground
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Placeholder

    private var shimmerPlaceholder: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.platformTertiaryGroupedBackground)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(height: 12)
                    .frame(maxWidth: 180)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(height: 10)
                    .frame(maxWidth: 140)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground.opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private var displayDomain: String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func loadMetadata() async {
        metadata = nil
        isLoading = true
        let result = await LinkPreviewService.shared.fetchMetadata(for: url)
        guard !Task.isCancelled else { return }
        withAnimation(Motion.media) {
            metadata = result
            isLoading = false
        }
    }
}
