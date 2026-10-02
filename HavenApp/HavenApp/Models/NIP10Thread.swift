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

    /// The kind a reply to `parentKind` is sent as. Replies match the thread:
    /// answering a comment sends a comment, anything else stays kind 1, which
    /// every client can show today. When the big clients render comments, flip
    /// this to always return `commentKind` for notes.
    static func replyKind(parentKind: Int) -> Int {
        parentKind == commentKind ? commentKind : 1
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
