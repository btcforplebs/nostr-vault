import SwiftUI

/// One chat row. A zap is the same row in gold with the amount in front of it —
/// same shape, so a busy chat still reads top to bottom.
struct LiveChatRowView: View {
    let message: LiveChatMessage
    let profile: FeedProfile?
    /// Tapping the avatar or the name opens that person's profile.
    var onOpenProfile: (String) -> Void = { _ in }
    /// Tapping a photo, GIF or video opens it large; nil leaves it in place.
    var onOpenMedia: ((URL) -> Void)? = nil

    private var displayName: String {
        guard let author = message.authorPubkey else { return "Someone" }
        return profile?.bestName ?? String(author.prefix(8))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // A zap with an unproven payer names nobody and opens nothing.
            if let author = message.authorPubkey {
                Button { onOpenProfile(author) } label: {
                    AvatarView(url: profile?.pictureURL, pubkey: author, size: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(displayName)'s profile")
            } else {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.orange)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }

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
                    if let author = message.authorPubkey {
                        Button { onOpenProfile(author) } label: {
                            Text(displayName)
                                .font(.appSystem(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens their profile")
                    } else {
                        Text(displayName)
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.createdAt))))
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary)
                }

                let parts = LiveChatMedia.split(message.text)
                if !parts.text.isEmpty {
                    Text(parts.text)
                        .font(.appSystem(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Photos, GIFs and videos at one size, so a busy chat keeps
                // its rhythm; a GIF plays, a video shows its frame and plays
                // muted when the owner autoplays videos.
                ForEach(parts.media, id: \.self) { url in
                    FeedMediaView(url: url, onTap: onOpenMedia.map { open in { open(url) } },
                                  isThumbnail: true, animatesThumbnail: true)
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
}
