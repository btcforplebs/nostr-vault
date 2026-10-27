import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A note's formatted text with each `:shortcode:` its NIP-30 tags give an
/// image for drawn as that image, a line of text tall. A shortcode shows as
/// text until its image has loaded, and stays text if it can't.
/// Android: `CustomEmojiText.kt`.
struct CustomEmojiText: View {
    let text: AttributedString
    let emojis: [String: CustomEmoji]
    let fontSize: CGFloat

    @State private var images: [String: PlatformImage] = [:]

    var body: some View {
        Self.compose(text, emojis: emojis, images: images)
            .task(id: emojis.values.map(\.url).sorted()) { await load() }
    }

    /// `text` as one `Text`, with every tagged shortcode that has an image swapped for it.
    static func compose(_ text: AttributedString, emojis: [String: CustomEmoji], images: [String: PlatformImage]) -> Text {
        var hits: [(range: Range<AttributedString.Index>, image: PlatformImage)] = []
        for emoji in emojis.values {
            guard let image = images[emoji.url] else { continue }
            var start = text.startIndex
            while start < text.endIndex, let found = text[start...].range(of: emoji.content) {
                hits.append((found, image))
                start = found.upperBound
            }
        }
        guard !hits.isEmpty else { return Text(text) }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out = Text("")
        var cursor = text.startIndex
        for hit in hits where hit.range.lowerBound >= cursor {
            out = out + Text(AttributedString(text[cursor..<hit.range.lowerBound]))
            out = out + Text(Image(platformImage: hit.image)).baselineOffset(-3)
            cursor = hit.range.upperBound
        }
        if cursor < text.endIndex { out = out + Text(AttributedString(text[cursor...])) }
        return out
    }

    private func load() async {
        let side = (fontSize * 1.25).rounded()
        for emoji in emojis.values where images[emoji.url] == nil {
            guard let url = URL(string: emoji.url), let image = await Self.image(at: url) else { continue }
            images[emoji.url] = Self.scaled(image, side: side)
        }
    }

    private static func image(at url: URL) async -> PlatformImage? {
        if let cached = MediaCacheService.shared.cachedImage(for: url) { return cached }
        if let data = MediaCacheService.shared.loadFromCache(url: url), let image = PlatformImage(data: data) {
            MediaCacheService.shared.cacheImage(image, for: url)
            return image
        }
        guard let (data, _) = try? await MediaSessionService.shared.session.data(from: url),
              let image = PlatformImage(data: data) else { return nil }
        MediaCacheService.shared.saveToCache(url: url, data: data)
        MediaCacheService.shared.cacheImage(image, for: url)
        return image
    }

    /// `Text(Image)` draws at the image's own size, so it is drawn to fit a
    /// square `side` points across first.
    private static func scaled(_ image: PlatformImage, side: CGFloat) -> PlatformImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(side / size.width, side / size.height)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: target).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        #else
        let copy = image.copy() as? NSImage ?? image
        copy.size = target
        return copy
        #endif
    }
}
