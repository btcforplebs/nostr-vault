import Foundation

/// Where to look for a reply's ancestors besides our own relays: the relay
/// hint in each ancestor `e` tag, and the write relays of each ancestor's
/// author (the `e` tag's 5th slot, or the reply's `p` target for the direct
/// parent when older clients leave that slot empty). Android does the same
/// (FeedServiceNoteFetching.kt). A parent that lives only on its author's
/// relay never loaded in the note view before this.
enum ParentLookupRelays {
    /// At most this many write relays per author, and this many extra relays
    /// in total, so one note view can't open dozens of sockets.
    static let outboxPerAuthor = 3
    static let maxExtra = 8

    /// Ancestor `e` tags (mentions skipped), as the note view fetches them.
    static func ancestorTags(_ tags: [[String]]) -> [[String]] {
        tags.filter { $0.count >= 2 && $0[0] == "e" && !($0.count >= 4 && $0[3] == "mention") }
    }

    /// Authors of the ancestors, from the tags.
    static func authors(tags: [[String]], replyToPubkey: String?) -> [String] {
        var out: [String] = []
        let ancestors = ancestorTags(tags)
        for tag in ancestors where tag.count >= 5 && tag[4].count == 64 && !out.contains(tag[4]) {
            out.append(tag[4])
        }
        if out.isEmpty, let p = replyToPubkey, p.count == 64 { out.append(p) }
        return out
    }

    /// Extra relay URLs to ask, beyond `known` (compared without a trailing
    /// slash and case). `outbox` gives an author's write relays, nil when not
    /// known yet.
    static func extraRelays(tags: [[String]], replyToPubkey: String?,
                            known: [String], outbox: (String) -> [String]?) -> [String] {
        func key(_ s: String) -> String {
            var k = s.trimmingCharacters(in: .whitespaces).lowercased()
            while k.hasSuffix("/") { k.removeLast() }
            return k
        }
        var seen = Set(known.map(key))
        var out: [String] = []
        func add(_ url: String) {
            guard out.count < maxExtra,
                  url.hasPrefix("wss://") || url.hasPrefix("ws://"),
                  URL(string: url) != nil,
                  seen.insert(key(url)).inserted else { return }
            out.append(url)
        }
        for tag in ancestorTags(tags) where tag.count >= 3 { add(tag[2]) }
        for author in authors(tags: tags, replyToPubkey: replyToPubkey) {
            for url in (outbox(author) ?? []).prefix(outboxPerAuthor) { add(url) }
        }
        return out
    }
}
