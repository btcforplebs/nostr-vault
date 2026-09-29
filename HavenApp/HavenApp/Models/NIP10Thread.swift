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
    static func parentEventId(tags: [[String]]) -> String? {
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        if let reply = eTags.first(where: { marker($0) == "reply" }) { return reply[1] }
        if let root = eTags.first(where: { marker($0) == "root" }) { return root[1] }
        return eTags.last(where: { marker($0) != "mention" })?[1]
    }

    private static func marker(_ tag: [String]) -> String {
        tag.count >= 4 ? tag[3] : ""
    }
}
