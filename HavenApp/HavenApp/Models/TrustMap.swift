import Foundation

/// The pure parts of the Web of Trust map: where each person sits, which
/// follow lists to ask for next, and the 3-hop "look deeper" chains. No
/// layout is ever iterated: a person's spot comes straight from their key, so
/// the same person sits in the same place every time the map opens.
enum TrustMap {
    /// Follow lists asked for per "show everyone" batch. Each list is a whole
    /// follow list (~90 KB at 1,000 follows), so one batch is ~2 MB.
    static let batchSize = 20
    /// Stop "show everyone" here (~9 MB). Past it the button asks again.
    static let maxBatchedLists = 100
    /// Lists tagging the author fetched from anyone for "look deeper".
    static let deeperSeeds = 30
    /// Lists from your follows that tag one of those seeds.
    static let deeperLinks = 12
    /// Faces drawn for 3-hop chains; the rest stay dots.
    static let shownChains = 12

    /// Where someone sits on a ring, in degrees from 0 up to 360, from the
    /// first 8 hex digits of their key. Not a hash of a hash: the key is
    /// already uniformly random, so its leading bits spread people evenly.
    static func angle(of pubkey: String) -> Double {
        fraction(pubkey, from: 0) * 360
    }

    /// −1…1 from the next 4 hex digits: a small in-or-out nudge so a thousand
    /// dots form a band instead of piling onto one line.
    static func band(of pubkey: String) -> Double {
        fraction(pubkey, from: 8) * 2 - 1
    }

    private static func fraction(_ pubkey: String, from offset: Int) -> Double {
        let hex = pubkey.dropFirst(offset).prefix(8)
        if hex.count == 8, let value = UInt32(hex, radix: 16) {
            return Double(value) / 4_294_967_296
        }
        // Not hex (only in tests or a malformed tag): FNV-1a, still stable.
        var hash: UInt32 = 2_166_136_261
        for byte in pubkey.utf8.dropFirst(offset) { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash) / 4_294_967_296
    }

    /// Up to `count` of `sorted`, evenly spaced through it. Keys sort in ring
    /// order (the angle is the key's leading digits), so taking the first few
    /// would bunch every face on one arc; spacing them spreads faces around.
    static func spread(_ sorted: [String], count: Int) -> [String] {
        guard sorted.count > count, count > 0 else { return sorted }
        return (0..<count).map { sorted[$0 * sorted.count / count] }
    }

    /// The next "show everyone" filter: follows whose lists haven't come back
    /// yet, tagging the author. nil once every follow has been asked about.
    static func nextBatch(author: String, follows: [String], seen: Set<String>) -> [String: Any]? {
        let authors = follows.filter { $0 != author && !seen.contains($0) }
        guard !authors.isEmpty else { return nil }
        return ["kinds": [3], "authors": authors, "#p": [author], "limit": batchSize]
    }

    /// The p-tags of the newest follow list `owner` signed: who they follow.
    /// Lists from anyone else are ignored. nil when no list came back.
    static func follows(of owner: String, in lists: [[String: Any]]) -> [String]? {
        var best: (createdAt: Int, tags: [[String]])?
        for list in lists {
            guard list["kind"] as? Int == 3, list["pubkey"] as? String == owner,
                  let tags = list["tags"] as? [[String]] else { continue }
            let createdAt = (list["created_at"] as? Int) ?? 0
            if let best, best.createdAt >= createdAt { continue }
            best = (createdAt, tags)
        }
        guard let best else { return nil }
        var seen = Set<String>()
        return best.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p", tag[1].count == 64, tag[1] != owner,
                  seen.insert(tag[1]).inserted else { return nil }
            return tag[1]
        }
    }

    /// One 3-hop route: you follow `bridge`, who follows `via`, who follows
    /// the author.
    struct Chain: Equatable {
        let bridge: String
        let via: String
    }

    /// Step 1 of "look deeper": anyone's follow list that tags the author.
    static func deeperSeedFilter(author: String) -> [String: Any] {
        ["kinds": [3], "#p": [author], "limit": deeperSeeds]
    }

    /// Who the seed lists say follows the author, minus you, your follows and
    /// the author: those are the possible middle steps. Keeps people already
    /// in your trust graph first when it's loaded, since they are the ones
    /// your follows most likely follow.
    static func deeperVia(author: String, me: String, follows: Set<String>, trustGraph: Set<String>,
                          seeds: [[String: Any]]) -> [String] {
        let candidates = TrustPath.allBridges(author: author, me: me, follows: allSigners(seeds),
                                              contactLists: seeds)
            .filter { !follows.contains($0) }
        guard !trustGraph.isEmpty else { return candidates }
        return candidates.filter(trustGraph.contains) + candidates.filter { !trustGraph.contains($0) }
    }

    /// Step 2: lists from your follows that tag any of the middle steps.
    static func deeperLinkFilters(follows: [String], via: [String], chunkSize: Int = 1000) -> [[String: Any]] {
        guard !via.isEmpty else { return [] }
        return stride(from: 0, to: follows.count, by: chunkSize).map { start in
            let chunk = Array(follows[start..<min(start + chunkSize, follows.count)])
            return ["kinds": [3], "authors": chunk, "#p": via, "limit": deeperLinks]
        }
    }

    /// Every route the link lists show, sorted by middle step then bridge.
    /// Only each follow's newest list counts, as in `TrustPath.resolve`.
    static func chains(me: String, follows: Set<String>, via: [String], links: [[String: Any]]) -> [Chain] {
        let viaSet = Set(via)
        var routes = Set<String>()
        var chains: [Chain] = []
        for bridge in allSigners(links).filter(follows.contains).sorted() where bridge != me {
            for target in Self.follows(of: bridge, in: links) ?? [] where viaSet.contains(target) {
                if routes.insert(bridge + target).inserted {
                    chains.append(Chain(bridge: bridge, via: target))
                }
            }
        }
        return chains.sorted { ($0.via, $0.bridge) < ($1.via, $1.bridge) }
    }

    private static func allSigners(_ lists: [[String: Any]]) -> Set<String> {
        Set(lists.compactMap { $0["pubkey"] as? String })
    }
}
