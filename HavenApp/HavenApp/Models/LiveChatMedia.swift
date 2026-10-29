import Foundation

/// The media in a live chat message: photo, GIF and video links come out of
/// the text and show under it, in the order they were written.
///
/// Kept free of SwiftUI so `MediaLogicTests` can compile it.
enum LiveChatMedia {
    /// Tiles per message. Each one is a fetch from whatever host the sender
    /// chose, made by every viewer, so links past this stay text (Tron, PR 1306).
    static let maxMedia = 4

    static func split(_ text: String) -> (text: String, media: [URL]) {
        var media: [URL] = []
        var kept: [String] = []
        // Lines kept apart: a link the composer put on its own line must not
        // glue the words either side of it together.
        for line in text.components(separatedBy: "\n") {
            var words: [Substring] = []
            for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = mediaURL(trimmed), media.contains(url) || media.count < maxMedia {
                    if !media.contains(url) { media.append(url) }
                } else {
                    words.append(word)
                }
            }
            kept.append(words.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        }
        let body = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, media)
    }

    /// An http(s) link whose file is a picture, a GIF or a video.
    static func mediaURL(_ word: String) -> URL? {
        guard word.hasPrefix("https://") || word.hasPrefix("http://"),
              let url = URL(string: word) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard SupportedMediaFormats.imageOrGifExtensions.contains(ext)
                || SupportedMediaFormats.videoExtensions.contains(ext) else { return nil }
        return url
    }
}
