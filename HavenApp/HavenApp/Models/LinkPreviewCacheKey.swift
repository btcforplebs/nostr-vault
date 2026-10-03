import Foundation
import CryptoKit

/// The on-disk filename a cached link preview is stored under.
///
/// It has to be a real digest of the whole URL. The first version took hex of
/// the URL's own bytes and truncated it to 64 characters — which is the first
/// 32 characters of the URL, not a hash — so every TestFlight invite, every
/// GitHub PR and every YouTube video shared one cache entry, and the preview
/// you saw was whichever of them was fetched first.
enum LinkPreviewCacheKey {
    static func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

/// Which of a note's links get a preview card — and so leave the text.
///
/// Capped: every card fetches its page, and one note can carry thousands of
/// URLs to a host the poster controls, so drawing them all turned a single
/// spam note into that many requests from the phone (Tron, Android #183).
/// Links past the cap stay in the text as ordinary tappable links.
enum LinkCards {
    static let max = 3

    static func shown(_ links: [URL]) -> [URL] {
        Array(links.prefix(max))
    }
}

/// Finding and removing http(s) URLs in note text — the one URL rule the
/// formatter, the condensed line and the tests share.
enum NoteURLs {
    /// A bare URL not already inside markdown link syntax. Trailing
    /// punctuation is left out, so "see https://x.com/a." keeps its full stop.
    static let httpRegex = try! NSRegularExpression(pattern: #"(?<![(\[])https?://[^\s<>\")\]]*[^\s<>\")\].,;:!?'\"]"#, options: .caseInsensitive)

    /// Removes `urls` from `text`, then closes the gaps they leave.
    ///
    /// A URL is removed only where the regex matches it whole. With the link
    /// cap, some links stay in the text, and a substring replace would cut a
    /// shown `https://a.com` out of a kept `https://a.com/login`, leaving
    /// "/login" (Tron, #184). A URL the regex never matches whole (one right
    /// after `(` or `[`) falls back to a plain replace, longest first.
    static func strip(_ urls: [URL], from text: String) -> String {
        let wanted = Set(urls.map(\.absoluteString))
        var result = text
        var removed = Set<String>()
        let ns = text as NSString
        for match in httpRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let found = ns.substring(with: match.range)
            let key = URL(string: found)?.absoluteString ?? found
            guard wanted.contains(key), let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
            removed.insert(key)
        }
        for url in wanted.subtracting(removed).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: url, with: "")
        }
        // A URL cut from mid-sentence leaves its two spaces behind.
        return result
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
