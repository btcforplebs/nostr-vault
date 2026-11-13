import SwiftUI

/// A NIP-30 custom emoji's image, square, read out as its shortcode. Until
/// the image loads (or when it can't: offline, a dead link) the shortcode
/// shows instead, so a slot is never blank. Android: `CustomEmojiImage.kt`.
struct CustomEmojiImage: View {
    let emoji: CustomEmoji
    let size: CGFloat
    /// The vault's saved copy (EmojiVaultStore), drawn first: a dead link
    /// still shows once the image has been saved.
    @State private var saved: PlatformImage?

    var body: some View {
        Group {
            if let saved {
                Image(platformImage: saved).resizable().aspectRatio(contentMode: .fit)
            } else if let url = URL(string: emoji.url) {
                CachedAsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(emoji.content)
        .task(id: emoji.url) { saved = await Self.savedCopy(emoji.url) }
    }

    /// The saved copy's image, off the main thread, once per file.
    private static func savedCopy(_ url: String) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) {
            guard let file = EmojiVaultStore.localFile(forURL: url) else { return nil }
            if let hit = MediaCacheService.shared.cachedImage(for: file) { return hit }
            guard let data = try? Data(contentsOf: file), let image = PlatformImage(data: data) else { return nil }
            MediaCacheService.shared.cacheImage(image, for: file)
            return image
        }.value
    }

    private var fallback: some View {
        Text(emoji.shortcode)
            .font(.system(size: max(7, size * 0.3)))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// One reaction as the app draws it: `custom`'s image when it has one, else
/// `emoji` as text. `fontSize` sizes both, so a custom emoji sits in a row of
/// Unicode ones at the same height.
struct ReactionGlyph: View {
    let emoji: String
    let custom: CustomEmoji?
    let fontSize: CGFloat

    init(_ emoji: String, custom: CustomEmoji?, fontSize: CGFloat) {
        self.emoji = emoji
        self.custom = custom
        self.fontSize = fontSize
    }

    init(_ pick: ReactionPick, fontSize: CGFloat) {
        self.init(pick.content, custom: pick.custom, fontSize: fontSize)
    }

    var body: some View {
        if let custom {
            CustomEmojiImage(emoji: custom, size: fontSize * 1.25)
        } else {
            Text(emoji).font(.system(size: fontSize))
        }
    }
}
