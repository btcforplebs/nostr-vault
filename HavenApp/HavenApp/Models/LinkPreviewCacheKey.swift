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
/// card list, the strip and the formatter share.
enum NoteURLs {
    /// Every http(s) URL in note text: what gets a link card. Trailing
    /// punctuation is left out, so "see https://x.com/a." keeps its full stop.
    static let cardRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>\")\]]*[^\s<>\")\].,;:!?'\"]"#, options: .caseInsensitive)

    /// The same URL, but not right after `(` or `[`: for linkifying bare URLs,
    /// where a URL in that position is already inside a markdown link.
    static let httpRegex = try! NSRegularExpression(pattern: #"(?<![(\[])https?://[^\s<>\")\]]*[^\s<>\")\].,;:!?'\"]"#, options: .caseInsensitive)

    /// Removes `urls` from `text`, then closes the gaps they leave.
    ///
    /// A URL is removed only where `cardRegex` — the pattern that chose the
    /// cards — matches it whole. With the link cap some links stay in the
    /// text, and a substring replace cut a shown `https://a.com` out of a kept
    /// `https://a.com/login`, leaving "/login" (Tron, #184). There is no
    /// substring fallback: a URL that is never a whole match stays in the text,
    /// which shows too much rather than cutting another link apart.
    static func strip(_ urls: [URL], from text: String) -> String {
        let wanted = Set(urls.map(\.absoluteString))
        var result = text
        let ns = text as NSString
        for match in cardRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let found = ns.substring(with: match.range)
            let key = URL(string: found)?.absoluteString ?? found
            guard wanted.contains(key), let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
        }
        // A URL cut from mid-sentence leaves its two spaces behind.
        return result
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One piece of a note in reading order: text, or a link that gets a card.
    enum Segment: Equatable {
        case text(String)
        case link(URL)
    }

    /// `text` cut at each link in `cards`, so each card draws where its link
    /// was written instead of in a pile under the note.
    ///
    /// Same whole-match rule as `strip`: a card's URL inside a longer kept URL
    /// stays text. A link written twice gets its card at the first spot and
    /// leaves the text at the second, as `strip` did. Text pieces are trimmed;
    /// empty ones are dropped.
    static func segments(_ text: String, cards: [URL]) -> [Segment] {
        guard !cards.isEmpty else { return piece(text).map { [.text($0)] } ?? [] }
        let wanted = Set(cards.map(\.absoluteString))
        var placed = Set<String>()
        var result: [Segment] = []
        var pending = ""
        let ns = text as NSString
        var cursor = 0
        for match in cardRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: match.range)
            let key = URL(string: found)?.absoluteString ?? found
            guard wanted.contains(key) else { continue }
            pending += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            guard placed.insert(key).inserted, let url = URL(string: found) else { continue }
            if let piece = piece(pending) { result.append(.text(piece)) }
            pending = ""
            result.append(.link(url))
        }
        pending += ns.substring(from: cursor)
        if let piece = piece(pending) { result.append(.text(piece)) }
        return result
    }

    /// A text piece as drawn: gaps left by a removed URL closed, ends trimmed.
    private static func piece(_ text: String) -> String? {
        let trimmed = text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How a collapsed note shows its text pieces and inline cards within one
/// line budget, so cutting text into pieces keeps the 8-line clamp.
enum NoteClamp {
    enum Show: Equatable {
        case full
        case lines(Int)
        case hidden

        /// The `lineLimit` to draw a text piece with.
        var lineLimit: Int? {
            if case .lines(let n) = self { return n }
            return nil
        }
    }

    /// Lines in a text block `height` tall, given one line's height and the
    /// spacing between lines.
    static func lineCount(height: CGFloat, lineHeight: CGFloat, spacing: CGFloat) -> Int {
        guard lineHeight > 0 else { return 0 }
        return max(1, Int(((height + spacing) / (lineHeight + spacing)).rounded()))
    }

    /// One `Show` per segment, and whether anything was cut (for "Show more").
    ///
    /// Text spends the budget in reading order; the piece that runs over it is
    /// clamped to what is left and everything after is hidden. A card costs no
    /// lines — collapsed notes always showed their cards — but only draws if
    /// the text before it fit. `lines[i]` is the measured line count of text
    /// segment `i`; until it is known that piece takes the rest of the budget.
    static func plan(_ segments: [NoteURLs.Segment], lines: [Int: Int], budget: Int) -> (shows: [Show], cut: Bool) {
        var remaining = budget
        var cut = false
        var shows: [Show] = []
        for (i, segment) in segments.enumerated() {
            guard remaining > 0 else {
                shows.append(.hidden)
                cut = true
                continue
            }
            switch segment {
            case .link:
                shows.append(.full)
            case .text:
                if let n = lines[i], n <= remaining {
                    shows.append(.full)
                    remaining -= n
                } else {
                    shows.append(.lines(remaining))
                    if lines[i] != nil { cut = true }
                    remaining = 0
                }
            }
        }
        return (shows, cut)
    }
}
