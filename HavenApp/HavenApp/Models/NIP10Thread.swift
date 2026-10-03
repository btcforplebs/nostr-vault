import Foundation

/// NIP-10: which event a note answers, read from its `e` tags. Shared by
/// `NostrEvent` and `FeedNote` so the feed, thread grouping and the detail view
/// agree on one rule. The Kotlin twin is `NIP10Thread.kt`.
enum NIP10Thread {
    /// The event this note replies to, or nil if it is not a reply.
    ///
    /// - An `e` tag marked "reply" names the parent.
    /// - Failing that, one marked "root" does: a direct reply to the root.
    /// - Unmarked tags are the deprecated positional form, where the last one
    ///   is the parent.
    /// - A tag marked "mention" is a quote, never a parent. Treating it as one
    ///   hung every quote under the note it quotes, and a reply that also
    ///   quoted something came out as a reply to the quote, because the
    ///   mention is usually the last `e` tag.
    ///
    /// A NIP-22 comment (kind 1111) names its parent in its lowercase `e` tag
    /// and its root in the uppercase `E`. Its `e` tags carry the parent's pubkey
    /// in the fourth slot, not a marker, so the NIP-10 reading below would get
    /// them wrong. A comment whose parent is not an event (an `a` or `i`
    /// target) has no parent id.
    static func parentEventId(kind: Int, tags: [[String]]) -> String? {
        if kind == commentKind {
            return tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
        }
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        if let reply = eTags.first(where: { marker($0) == "reply" }) { return reply[1] }
        if let root = eTags.first(where: { marker($0) == "root" }) { return root[1] }
        return eTags.last(where: { marker($0) != "mention" })?[1]
    }

    /// The thread root this note hangs under, or nil if the note has none and
    /// is a root itself. NIP-22 names it in the uppercase `E`; NIP-10 in the
    /// tag marked "root", or the first non-mention `e` in the positional form.
    static func rootEventId(kind: Int, tags: [[String]]) -> String? {
        if kind == commentKind {
            return tags.first(where: { $0.count >= 2 && $0[0] == "E" })?[1]
        }
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" && marker($0) != "mention" }
        return (eTags.first(where: { marker($0) == "root" }) ?? eTags.first)?[1]
    }

    /// NIP-22 comment kind. Replies to notes are moving to it (NIP PR #2447),
    /// and Amethyst, Ditto, Coracle and Snort already send it.
    static let commentKind = 1111

    /// True for a comment that belongs to a kind 1 note thread (root kind
    /// `K` is 1). Comments on videos, articles and other kinds are not
    /// conversation the feed knows how to show.
    static func isNoteComment(kind: Int, tags: [[String]]) -> Bool {
        kind == commentKind && tags.contains { $0.count >= 2 && $0[0] == "K" && $0[1] == "1" }
    }

    /// The kind a response to `parentKind` is sent as.
    ///
    /// - A comment answers a comment (1111 → 1111).
    /// - Kind 1 replies are only valid onto a kind 1 parent (NIP-10), so
    ///   anything else — an article, a video, a picture — gets a comment.
    /// - Onto a kind 1 note it's a kind 1 reply by default: that's what most
    ///   clients show under a note today. `asComment` sends a comment instead,
    ///   which the composer offers on an original note (not on a reply: a
    ///   reply to a reply stays kind 1).
    static func replyKind(parentKind: Int, asComment: Bool = false) -> Int {
        if parentKind == commentKind { return commentKind }
        if parentKind == 1 { return asComment ? commentKind : 1 }
        return commentKind
    }

    /// True for a kind 1 note that isn't itself a reply: the one place the
    /// composer offers a choice between a reply and a comment.
    static func isOriginalNote(kind: Int, tags: [[String]]) -> Bool {
        kind == 1 && parentEventId(kind: kind, tags: tags) == nil
    }

    /// The `a`/`A` coordinate of an addressable (30000–39999) or replaceable
    /// (0, 3, 10000–19999) event; replaceables keep the trailing colon.
    static func coordinate(kind: Int, pubkey: String, tags: [[String]]) -> String? {
        if kind >= 30000 && kind < 40000 {
            guard let d = tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return nil }
            return "\(kind):\(pubkey):\(d)"
        }
        if kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000) {
            return "\(kind):\(pubkey):"
        }
        return nil
    }

    /// NIP-22 tags for a top-level comment on `parent`, which is also the
    /// root. A regular event is rooted by `E`; an addressable or replaceable
    /// one by `A` alone, with the parent named by `a` and this version's `e`.
    static func topLevelCommentTags(parentId: String, parentKind: Int, parentPubkey: String, parentTags: [[String]], relayHint: String) -> [[String]] {
        var tags: [[String]] = []
        if let coord = coordinate(kind: parentKind, pubkey: parentPubkey, tags: parentTags) {
            tags.append(["A", coord, relayHint])
            tags.append(["K", String(parentKind)])
            tags.append(["P", parentPubkey])
            tags.append(["a", coord, relayHint])
            tags.append(["e", parentId, relayHint, parentPubkey])
        } else {
            tags.append(["E", parentId, relayHint, parentPubkey])
            tags.append(["K", String(parentKind)])
            tags.append(["P", parentPubkey])
            tags.append(["e", parentId, relayHint, parentPubkey])
        }
        tags.append(["k", String(parentKind)])
        tags.append(["p", parentPubkey])
        return tags
    }

    /// NIP-22 tags for any comment: on a comment it copies that comment's
    /// root and points at it; on anything else the parent is the root.
    static func commentTags(parentId: String, parentKind: Int, parentPubkey: String, parentTags: [[String]], relayHint: String) -> [[String]] {
        parentKind == commentKind
            ? commentReplyTags(parentId: parentId, parentPubkey: parentPubkey, parentTags: parentTags, relayHint: relayHint)
            : topLevelCommentTags(parentId: parentId, parentKind: parentKind, parentPubkey: parentPubkey, parentTags: parentTags, relayHint: relayHint)
    }

    /// NIP-22 tags for a comment answering the comment `parent`: the root
    /// scope (`E`/`A`/`I`, `K`, `P`) is copied from the parent unchanged, and
    /// the parent itself goes in `e`, `k`, `p`.
    static func commentReplyTags(parentId: String, parentPubkey: String, parentTags: [[String]], relayHint: String) -> [[String]] {
        var tags = parentTags.filter { $0.count >= 2 && ["E", "A", "I", "K", "P"].contains($0[0]) }
        tags.append(["e", parentId, relayHint, parentPubkey])
        tags.append(["k", String(commentKind)])
        tags.append(["p", parentPubkey])
        return tags
    }

    private static func marker(_ tag: [String]) -> String {
        tag.count >= 4 ? tag[3] : ""
    }
}
