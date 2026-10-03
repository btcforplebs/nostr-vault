import Foundation

/// Tags for reacting to and highlighting a long-form article.
///
/// An article is addressable, so a like or a highlight has to name it by its
/// `a` coordinate as well as this version's `e` id — otherwise clients that
/// count by coordinate never see it, and an edit orphans it.
enum ArticleEngagement {
    static let highlightKind = 9802

    /// NIP-25 reaction tags. `a` only appears when the event is addressable.
    static func reactionTags(id: String, kind: Int, pubkey: String, tags: [[String]], relayHint: String) -> [[String]] {
        var out: [[String]] = [["e", id, relayHint, pubkey]]
        if let coord = NIP10Thread.coordinate(kind: kind, pubkey: pubkey, tags: tags) {
            out.append(["a", coord, relayHint])
        }
        out.append(["p", pubkey])
        out.append(["k", String(kind)])
        return out
    }

    /// NIP-84 highlight tags. `context` is the surrounding paragraph and is
    /// only sent when the highlight is a trimmed part of it; `comment` turns
    /// it into a quote highlight.
    static func highlightTags(id: String, kind: Int, pubkey: String, tags: [[String]], relayHint: String,
                              passage: String, context: String, comment: String) -> [[String]] {
        var out: [[String]] = []
        if let coord = NIP10Thread.coordinate(kind: kind, pubkey: pubkey, tags: tags) {
            out.append(["a", coord, relayHint])
        }
        out.append(["e", id, relayHint])
        out.append(["p", pubkey, relayHint, "author"])
        let trimmedPassage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty, trimmedContext != trimmedPassage {
            out.append(["context", trimmedContext])
        }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            out.append(["comment", trimmedComment])
        }
        out.append(["alt", "Highlight: \"\(trimmedPassage)\""])
        return out
    }

    /// The highlightable text of a markdown block, with inline markup
    /// stripped so the published passage reads like what's on screen.
    static func plainText(_ markdown: String) -> String {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(attributed.characters)
        }
        return markdown
    }

    /// Relay filters for other people's highlights of an article. A
    /// highlight names an article by its `a` coordinate (so it survives
    /// edits); older or simpler clients use only this version's `e` id.
    static func highlightFilters(id: String, coordinate: String?, limit: Int = 200) -> [[String: Any]] {
        var filters: [[String: Any]] = [["kinds": [highlightKind], "#e": [id], "limit": limit]]
        if let coordinate {
            filters.insert(["kinds": [highlightKind], "#a": [coordinate], "limit": limit], at: 0)
        }
        return filters
    }

    /// Which text block a passage belongs to: the first whose plain text
    /// contains it, ignoring case and runs of whitespace. Nil when the
    /// passage is not in the article as shown (an earlier version, or text
    /// the highlighter trimmed differently) — it still appears in the list.
    static func blockIndex(for passage: String, in blocks: [String]) -> Int? {
        let needle = normalized(passage)
        guard !needle.isEmpty else { return nil }
        return blocks.firstIndex { normalized($0).contains(needle) }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Someone's highlight (NIP-84, kind 9802) of an article.
struct ArticleHighlight: Identifiable, Equatable {
    let id: String
    let pubkey: String
    let passage: String
    let comment: String?
    let createdAt: Date

    /// Accepts only a 9802 that points at this article — by its coordinate or
    /// by this version's id — and has a passage. The caller checks the
    /// signature; this checks the shape.
    init?(event: [String: Any], articleId: String, coordinate: String?) {
        guard (event["kind"] as? Int) == ArticleEngagement.highlightKind,
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let createdAt = (event["created_at"] as? NSNumber)?.doubleValue,
              let tags = event["tags"] as? [[String]] else { return nil }
        let pointsHere = tags.contains { tag in
            guard tag.count >= 2 else { return false }
            if tag[0] == "e" { return tag[1] == articleId }
            if tag[0] == "a", let coordinate { return tag[1] == coordinate }
            return false
        }
        let passage = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pointsHere, !passage.isEmpty else { return nil }
        let comment = tags.first { $0.count >= 2 && $0[0] == "comment" }?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.pubkey = pubkey
        self.passage = passage
        self.comment = (comment?.isEmpty ?? true) ? nil : comment
        self.createdAt = Date(timeIntervalSince1970: createdAt)
    }
}
