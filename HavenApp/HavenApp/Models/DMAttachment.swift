import Foundation

/// Photos and videos in direct messages. A photo or video is uploaded to Blossom and its URL sent
/// as part of an ordinary DM — NIP-17 or NIP-04 — exactly as Android's
/// DMThreadViewModel does, so a photo sent from either app arrives in the other
/// as the same message.
enum DMAttachment {
    /// The message to send: the typed text, then the photo's URL on its own
    /// line. Android builds it the same way.
    static func content(text: String, imageURL: URL?) -> String {
        content(text: text, mediaURL: imageURL)
    }

    /// The same for a photo or a video: the typed text, then its URL.
    static func content(text: String, mediaURL: URL?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mediaURL else { return trimmed }
        return trimmed.isEmpty ? mediaURL.absoluteString : trimmed + "\n" + mediaURL.absoluteString
    }

    /// A video's link as it is sent: its Blossom URL with the file's
    /// extension, so the other app (which tells videos by extension) shows
    /// it as a video, not a bare link.
    static func videoLink(_ url: URL, extension ext: String) -> URL {
        url.pathExtension.isEmpty && !ext.isEmpty ? url.appendingPathExtension(ext) : url
    }

    /// A received message split for display: the photos it links, in order and
    /// without repeats, and the text with those links taken out. Only http(s)
    /// links whose path ends in an image or GIF extension count — anything
    /// else stays in the text as the sender wrote it. `withVideos` also takes
    /// out video links (DMs show them as videos; Live chat keeps them as text).
    static func split(_ content: String, withVideos: Bool = false) -> (text: String, images: [URL], videos: [URL]) {
        var images: [URL] = []
        var videos: [URL] = []
        let lines = content.components(separatedBy: "\n").compactMap { line -> String? in
            var kept: [Substring] = []
            var removedAny = false
            for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                if let url = imageURL(String(word)) {
                    if !images.contains(url) { images.append(url) }
                    removedAny = true
                } else if withVideos, let url = mediaURL(String(word), extensions: SupportedMediaFormats.videoExtensions) {
                    if !videos.contains(url) { videos.append(url) }
                    removedAny = true
                } else {
                    kept.append(word)
                }
            }
            guard removedAny else { return line }
            let rest = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        guard !images.isEmpty || !videos.isEmpty else { return (content, [], []) }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images, videos)
    }

    private static func imageURL(_ word: String) -> URL? {
        mediaURL(word, extensions: SupportedMediaFormats.imageOrGifExtensions)
    }

    private static func mediaURL(_ word: String, extensions: Set<String>) -> URL? {
        let token = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: token),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              extensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }
}
