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

// MARK: - Likes, zaps and comments

/// What the network says about an article: likes, zaps and comments.
struct ArticleTally: Equatable {
    /// People who reacted, not reactions: one person liking twice is one like.
    var likers: Set<String> = []
    var zaps = 0
    var zapSats = 0
    /// Every comment, including replies to comments.
    var commentCount = 0
    /// Comments made on the article itself, oldest first. Replies to a
    /// comment are counted, and open from that comment.
    var topLevelComments: [[String: Any]] = []
    /// Replies to each comment, keyed by the comment's id.
    var replyCounts: [String: Int] = [:]

    static func == (lhs: ArticleTally, rhs: ArticleTally) -> Bool {
        lhs.likers == rhs.likers && lhs.zaps == rhs.zaps && lhs.zapSats == rhs.zapSats
            && lhs.commentCount == rhs.commentCount && lhs.replyCounts == rhs.replyCounts
            && lhs.topLevelComments.map { $0["id"] as? String } == rhs.topLevelComments.map { $0["id"] as? String }
    }
}

extension ArticleEngagement {
    static let reactionKind = 7
    static let zapReceiptKind = 9735
    /// NIP-22 comment, what NIP-23 asks for on an article.
    static let commentKind = 1111
    /// Older clients reply to an article with a plain kind 1 note.
    static let noteKind = 1

    /// Relay filters for an article's likes, zaps and comments. By `a`
    /// coordinate (survives edits) and by this version's `e` id; NIP-22
    /// comments also carry the article as their uppercase root, which is the
    /// only tag a reply to a comment has that points at the article.
    static func engagementFilters(id: String, coordinate: String?, limit: Int = 500) -> [[String: Any]] {
        let kinds = [reactionKind, zapReceiptKind, commentKind, noteKind]
        var filters: [[String: Any]] = [
            ["kinds": kinds, "#e": [id], "limit": limit],
            ["kinds": [commentKind], "#E": [id], "limit": limit],
        ]
        if let coordinate {
            filters.append(["kinds": kinds, "#a": [coordinate], "limit": limit])
            filters.append(["kinds": [commentKind], "#A": [coordinate], "limit": limit])
        }
        return filters
    }

    /// Counts what points at this article. The caller checks signatures and
    /// drops spam; this checks that each event really is about this article,
    /// since a relay may answer a tag filter loosely.
    static func tally(_ events: [[String: Any]], articleId: String, coordinate: String?, now: Date = Date()) -> ArticleTally {
        func names(_ value: String, as tagNames: Set<String>, in tags: [[String]]) -> Bool {
            tags.contains { $0.count >= 2 && tagNames.contains($0[0]) && $0[1] == value }
        }
        func pointsHere(_ tags: [[String]], lower: Bool = true, upper: Bool = false) -> Bool {
            var e: Set<String> = [], a: Set<String> = []
            if lower { e.insert("e"); a.insert("a") }
            if upper { e.insert("E"); a.insert("A") }
            if names(articleId, as: e, in: tags) { return true }
            if let coordinate, names(coordinate, as: a, in: tags) { return true }
            return false
        }

        var tally = ArticleTally()
        var seen = Set<String>()
        var comments: [(id: String, parent: String?, event: [String: Any], createdAt: Double)] = []

        for event in events {
            guard let id = event["id"] as? String, seen.insert(id).inserted,
                  let kind = event["kind"] as? Int,
                  let pubkey = event["pubkey"] as? String,
                  let tags = event["tags"] as? [[String]],
                  let createdAt = (event["created_at"] as? NSNumber)?.doubleValue,
                  createdAt <= now.timeIntervalSince1970 + ArticleHighlight.maxFutureSkew else { continue }
            let content = event["content"] as? String ?? ""

            switch kind {
            case reactionKind:
                // "-" is a dislike (NIP-25).
                guard pointsHere(tags), content != "-" else { continue }
                tally.likers.insert(pubkey)
            case zapReceiptKind:
                guard pointsHere(tags) else { continue }
                tally.zaps += 1
                var requestTags: [[String]] = []
                if let description = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                   let data = description.data(using: .utf8),
                   let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    requestTags = request["tags"] as? [[String]] ?? []
                }
                tally.zapSats += LiveChat.zapAmountSats(receiptTags: tags, requestTags: requestTags)
            case commentKind:
                guard pointsHere(tags, lower: true, upper: true) else { continue }
                // The lowercase tags name the parent. A comment whose parent
                // is the article is top-level; otherwise it replies to the
                // comment its lowercase `e` names.
                let parent = pointsHere(tags)
                    ? nil
                    : tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                comments.append((id, parent, event, createdAt))
            case noteKind:
                // A mention or quote names the article without replying to it.
                let replyTags = tags.filter { $0.count >= 2 && ($0[0] == "e" || $0[0] == "a") && ($0.count < 4 || $0[3] != "mention") }
                guard pointsHere(replyTags) else { continue }
                // NIP-10: the reply-marked `e` is the parent; with no markers
                // the last `e` is. Either way, top-level when it is the article.
                let eTags = replyTags.filter { $0[0] == "e" }
                let parentTag = eTags.first(where: { $0.count >= 4 && $0[3] == "reply" }) ?? eTags.last
                let parent = parentTag.map { $0[1] }
                comments.append((id, parent == articleId ? nil : parent, event, createdAt))
            default:
                continue
            }
        }

        tally.commentCount = comments.count
        for comment in comments {
            if let parent = comment.parent { tally.replyCounts[parent, default: 0] += 1 }
        }
        tally.topLevelComments = comments
            .filter { $0.parent == nil }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.event)
        return tally
    }
}
