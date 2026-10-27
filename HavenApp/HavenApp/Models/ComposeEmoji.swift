import Foundation

/// Custom emoji in the composer (NIP-30): the `:name` being typed, the emoji
/// that match it, putting one in, and the `emoji` tags a post needs. Pure,
/// so the rules are testable apart from the view. Offsets count Characters.
/// Android: `ui/screens/compose/ComposeEmoji.kt`.
enum ComposeEmoji {
    /// Suggestions start after this many letters, so a lone `:` or `:)` stays quiet.
    static let minQuery = 2
    static let maxSuggestions = 8

    struct Query: Equatable {
        let start: Int
        let end: Int
        let text: String
    }

    private static func isShortcodeChar(_ c: Character) -> Bool {
        (c.isASCII && (c.isLetter || c.isNumber)) || c == "_" || c == "-"
    }

    /// The `:name` the caret is at the end of, or nil. The `:` must start a
    /// word, so a time ("12:30") or a URL ("https://") doesn't count, and the
    /// name is at least `minQuery` shortcode characters.
    static func query(in text: String, caret: Int) -> Query? {
        let chars = Array(text)
        let end = min(max(caret, 0), chars.count)
        var i = end
        while i > 0, isShortcodeChar(chars[i - 1]) { i -= 1 }
        guard i > 0, chars[i - 1] == ":" else { return nil }
        let colon = i - 1
        if colon > 0, !chars[colon - 1].isWhitespace { return nil }
        let name = String(chars[i..<end])
        guard name.count >= minQuery else { return nil }
        return Query(start: colon, end: end, text: name)
    }

    /// The emoji whose shortcode contains `query`, once each by shortcode:
    /// those that start with it first, then the rest, each in `known` order.
    static func suggestions(_ query: String, known: [CustomEmoji], limit: Int = maxSuggestions) -> [CustomEmoji] {
        let q = query.lowercased()
        var seen = Set<String>()
        let unique = known.filter { seen.insert($0.shortcode).inserted && $0.shortcode.lowercased().contains(q) }
        let starts = unique.filter { $0.shortcode.lowercased().hasPrefix(q) }
        let rest = unique.filter { !$0.shortcode.lowercased().hasPrefix(q) }
        return Array((starts + rest).prefix(limit))
    }

    /// `text` with `query` replaced by `:shortcode: `, and the caret after it.
    static func insert(_ emoji: CustomEmoji, replacing query: Query, in text: String) -> (text: String, caret: Int) {
        var chars = Array(text)
        let end = min(query.end, chars.count)
        let start = min(max(query.start, 0), end)
        let replacement = Array(emoji.content + " ")
        chars.replaceSubrange(start..<end, with: replacement)
        return (String(chars), start + replacement.count)
    }

    /// `insertion` (Unicode or `:shortcode:`) put in at `caret`, with a space
    /// before a shortcode that would join the previous word, and the caret after it.
    static func insert(_ insertion: String, at caret: Int, in text: String) -> (text: String, caret: Int) {
        var chars = Array(text)
        let at = min(max(caret, 0), chars.count)
        let custom = insertion.hasPrefix(":")
        let before = custom && at > 0 && !chars[at - 1].isWhitespace ? " " : ""
        let piece = Array(before + insertion + (custom ? " " : ""))
        chars.insert(contentsOf: piece, at: at)
        return (String(chars), at + piece.count)
    }

    /// One `emoji` tag per shortcode the post uses that `known` has an image
    /// for, in the order they first appear. A `:word:` with no image gets none.
    static func tags(for content: String, known: [String: CustomEmoji]) -> [[String]] {
        var seen = Set<String>()
        return CustomEmoji.segments(content, emojis: known).compactMap { segment -> [String]? in
            guard case .emoji(let emoji) = segment, seen.insert(emoji.shortcode).inserted else { return nil }
            return emoji.tag
        }
    }
}
