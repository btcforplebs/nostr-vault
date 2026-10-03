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
}
