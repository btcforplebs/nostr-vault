import SwiftUI

/// One chat row. A zap is the same row in gold with the amount in front of it —
/// same shape, so a busy chat still reads top to bottom.
struct LiveChatRowView: View {
    let message: LiveChatMessage
    let profile: FeedProfile?

    private var displayName: String {
        profile?.bestName ?? String(message.authorPubkey.prefix(8))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(url: profile?.pictureURL, pubkey: message.authorPubkey, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let sats = message.zapSats {
                        Text(sats > 0 ? "⚡ \(sats)" : "⚡")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                    Text(displayName)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.createdAt))))
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary)
                }

                let parts = Self.split(message.text)
                if !parts.text.isEmpty {
                    Text(parts.text)
                        .font(.appSystem(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(parts.images, id: \.self) { url in
                    RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 400, height: 400))
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(message.isZap ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(message.isZap ? Color.orange.opacity(0.12) : Color.clear)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// Image links come out of the text and show as pictures under it.
    static func split(_ text: String) -> (text: String, images: [URL]) {
        var images: [URL] = []
        var kept: [Substring] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"),
               let url = URL(string: trimmed),
               SupportedMediaFormats.imageExtensions.contains(url.pathExtension.lowercased()) {
                if !images.contains(url) { images.append(url) }
            } else {
                kept.append(word)
            }
        }
        return (kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), images)
    }
}
