import Foundation

/// Photos in direct messages. A photo is uploaded to Blossom and its URL sent
/// as part of an ordinary DM — NIP-17 or NIP-04 — exactly as Android's
/// DMThreadViewModel does, so a photo sent from either app arrives in the other
/// as the same message.
enum DMAttachment {
    /// The message to send: the typed text, then the photo's URL on its own
    /// line. Android builds it the same way.
    static func content(text: String, imageURL: URL?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let imageURL else { return trimmed }
        return trimmed.isEmpty ? imageURL.absoluteString : trimmed + "\n" + imageURL.absoluteString
    }

    /// A received message split for display: the photos it links, in order and
    /// without repeats, and the text with those links taken out. Only http(s)
    /// links whose path ends in an image or GIF extension count — anything
    /// else stays in the text as the sender wrote it.
    static func split(_ content: String) -> (text: String, images: [URL]) {
        var images: [URL] = []
        let lines = content.components(separatedBy: "\n").compactMap { line -> String? in
            var kept: [Substring] = []
            var removedAny = false
            for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                if let url = imageURL(String(word)) {
                    if !images.contains(url) { images.append(url) }
                    removedAny = true
                } else {
                    kept.append(word)
                }
            }
            guard removedAny else { return line }
            let rest = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        guard !images.isEmpty else { return (content, []) }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images)
    }

    private static func imageURL(_ word: String) -> URL? {
        let token = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: token),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              SupportedMediaFormats.imageOrGifExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }
}
