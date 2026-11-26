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

    /// Ancestor `e` tags plus NIP-22 `E` root tags (mentions skipped), as
    /// the note view fetches them. A comment's root is named only by `E`, and
    /// often its only usable relay hint sits there (2026-11-26: a Mostr
    /// thread whose `e` hint was the poster's own 127.0.0.1 relay).
    static func ancestorTags(_ tags: [[String]]) -> [[String]] {
        tags.filter { $0.count >= 2 && ($0[0] == "e" || $0[0] == "E") && !($0.count >= 4 && $0[3] == "mention") }
    }

    /// One ancestor pointer read from a tag: its id, a relay hint others
    /// can reach (nil for none, loopback or LAN), and its author.
    struct Hint: Equatable {
        let id: String
        let relay: String?
        let author: String?
    }

    /// Every ancestor's hint, in tag order.
    static func hints(_ tags: [[String]]) -> [Hint] {
        ancestorTags(tags).map { tag in
            Hint(id: tag[1], relay: tag.count >= 3 ? reachableHint(tag[2]) : nil, author: author(in: tag))
        }
    }

    /// The tag's author: NIP-10 puts it in the fifth slot, NIP-22 (`e` and
    /// `E` of a kind 1111) in the fourth, where NIP-10 has its marker. A
    /// marker is never 64 hex characters, so no kind is needed to tell them.
    static func author(in tag: [String]) -> String? {
        if tag.count >= 5, isHexKey(tag[4]) { return tag[4] }
        if tag.count >= 4, isHexKey(tag[3]) { return tag[3] }
        return nil
    }

    /// `raw` when it is a websocket address outsiders can reach. A poster
    /// running only their phone's own relay writes `ws://127.0.0.1:3355`
    /// as the hint; asking it reaches our own phone, never theirs.
    static func reachableHint(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespaces)
        let lower = url.lowercased()
        let rest: Substring
        if lower.hasPrefix("wss://") { rest = url.dropFirst(6) } else if lower.hasPrefix("ws://") { rest = url.dropFirst(5) } else { return nil }
        guard !rest.isEmpty, URL(string: url) != nil,
              !HavenConfig.isPrivateNetworkHost(String(rest)) else { return nil }
        return url
    }

    private static func isHexKey(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    /// Authors of the ancestors, from the tags.
    static func authors(tags: [[String]], replyToPubkey: String?) -> [String] {
        var out: [String] = []
        for hint in hints(tags) {
            if let a = hint.author, !out.contains(a) { out.append(a) }
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
        for hint in hints(tags) { if let relay = hint.relay { add(relay) } }
        for author in authors(tags: tags, replyToPubkey: replyToPubkey) {
            for url in (outbox(author) ?? []).prefix(outboxPerAuthor) { add(url) }
        }
        return out
    }
}
