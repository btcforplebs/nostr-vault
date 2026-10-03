import Foundation

/// Tags for reacting to and highlighting a long-form article.
///
/// An article is addressable, so a like or a highlight has to name it by its
/// `a` coordinate as well as this version's `e` id — otherwise clients that
/// count by coordinate never see it, and an edit orphans it.
enum ArticleEngagement {
    static let highlightKind = 9802
    /// NIP-84 passages are a sentence or a paragraph. Anything longer is not
    /// a highlight, and each one is matched against the whole article.
    static let maxPassageLength = 1_000
    /// The newest this many are shown: keys are free, so the count is the
    /// publisher's choice, not the article's.
    static let maxShownHighlights = 50

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

    /// The highlights to show: newest first, at most `maxShownHighlights`.
    static func shown(_ highlights: [ArticleHighlight]) -> [ArticleHighlight] {
        var seen = Set<String>()
        return Array(highlights
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.id).inserted }
            .prefix(maxShownHighlights))
    }

    /// Each block's highlights, keyed by block id. Every block is normalized
    /// once, so the cost is one pass per highlight, not per highlight per
    /// block per re-render. Passages not in the text as shown are left out.
    static func place(_ highlights: [ArticleHighlight], in blocks: [(id: String, text: String)]) -> [String: [ArticleHighlight]] {
        let normalizedBlocks = blocks.map { normalized($0.text) }
        var out: [String: [ArticleHighlight]] = [:]
        for highlight in highlights {
            let needle = normalized(highlight.passage)
            guard !needle.isEmpty,
                  let index = normalizedBlocks.firstIndex(where: { $0.contains(needle) }) else { continue }
            out[blocks[index].id, default: []].append(highlight)
        }
        return out
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
    /// The 9802's own tags, kept so a reply can thread onto it.
    let tags: [[String]]

    /// Accepts only a 9802 that points at this article — by its coordinate or
    /// by this version's id — and has a passage. The caller checks the
    /// signature; this checks the shape.
    /// How far ahead of the clock a highlight may be dated. The newest are
    /// the ones shown, so a highlight dated in 2099 would push every real one
    /// off the list (Tron, #189); this allows only for clock drift.
    static let maxFutureSkew: TimeInterval = 600

    init?(event: [String: Any], articleId: String, coordinate: String?, now: Date = Date()) {
        guard (event["kind"] as? Int) == ArticleEngagement.highlightKind,
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let createdAt = (event["created_at"] as? NSNumber)?.doubleValue,
              createdAt <= now.timeIntervalSince1970 + Self.maxFutureSkew,
              let tags = event["tags"] as? [[String]] else { return nil }
        let pointsHere = tags.contains { tag in
            guard tag.count >= 2 else { return false }
            if tag[0] == "e" { return tag[1] == articleId }
            if tag[0] == "a", let coordinate { return tag[1] == coordinate }
            return false
        }
        let passage = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pointsHere, !passage.isEmpty, passage.count <= ArticleEngagement.maxPassageLength else { return nil }
        let comment = tags.first { $0.count >= 2 && $0[0] == "comment" }?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.pubkey = pubkey
        self.passage = passage
        self.comment = (comment?.isEmpty ?? true) ? nil : comment
        self.createdAt = Date(timeIntervalSince1970: createdAt)
        self.tags = tags
    }
}
