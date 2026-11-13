import Foundation

/// Find emoji sets (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.2 Browse): what to ask
/// the relays for and how the answers are shown. People you follow first,
/// then everyone's from the last month (limit 200, Amethyst's numbers), newest
/// copy per set, blocked people and empty sets left out. Pure, so
/// MediaLogicTests checks it. Android `service/emoji/EmojiSetBrowser.kt`, web
/// `web-vault/src/net/emoji-sets.js` (browseFilters / browseList).
enum EmojiSetBrowse {
    static let limit = 200
    static let since: TimeInterval = 30 * 86_400
    /// Follows per REQ, so one filter stays a size relays take.
    static let authorsPerAsk = 500
    /// A set dated further ahead than this is skipped (a wrong clock would pin it on top).
    static let maxSkew: Int64 = 600

    /// One 30030 as the relays sent it (signature already checked).
    struct Candidate: Equatable {
        let id: String
        let pubkey: String
        let createdAt: Int64
        let kind: Int
        let tags: [[String]]
    }

    struct Found: Equatable, Identifiable {
        let set: EmojiLibrary.EmojiSet
        let author: String
        let createdAt: Int64
        let byFollow: Bool
        var id: String { self.set.address }
    }

    /// The asks: the follows' sets (chunked), then everyone's since a month ago.
    static func filters(follows: [String], now: Date = Date()) -> [[String: Any]] {
        var seen = Set<String>()
        let people = follows.map { $0.lowercased() }.filter { FileNote.isHex64($0) && seen.insert($0).inserted }
        var out: [[String: Any]] = stride(from: 0, to: people.count, by: authorsPerAsk).map { start in
            ["kinds": [30030], "authors": Array(people[start..<min(start + authorsPerAsk, people.count)]), "limit": limit]
        }
        out.append(["kinds": [30030], "limit": limit, "since": Int64(now.timeIntervalSince1970 - since)])
        return out
    }

    /// `30030:<pubkey>:<d>` for a 30030 with a `d` tag, or nil.
    static func address(_ c: Candidate) -> String? {
        guard c.kind == 30030, let d = c.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return nil }
        let address = "30030:\(c.pubkey):\(d)"
        return EmojiListParse.setRef(address) != nil ? address : nil
    }

    /// Newest copy per set; blocked authors, empty sets and far-future ones
    /// out; sets by people you follow first, then newest first.
    static func list(_ events: [Candidate], follows: Set<String>, blocked: Set<String>, now: Date = Date()) -> [Found] {
        let latest = Int64(now.timeIntervalSince1970) + maxSkew
        var best: [String: Candidate] = [:]
        for c in events where c.createdAt < latest && !blocked.contains(c.pubkey) {
            guard let a = address(c) else { continue }
            if let have = best[a], have.createdAt > c.createdAt || (have.createdAt == c.createdAt && have.id <= c.id) { continue }
            best[a] = c
        }
        return best.compactMap { a, c -> Found? in
            let set = EmojiListParse.set(address: a, tags: c.tags)
            guard !set.emojis.isEmpty else { return nil }
            return Found(set: set, author: c.pubkey, createdAt: c.createdAt, byFollow: follows.contains(c.pubkey))
        }
        .sorted {
            if $0.byFollow != $1.byFollow { return $0.byFollow }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.set.address < $1.set.address
        }
    }
}
