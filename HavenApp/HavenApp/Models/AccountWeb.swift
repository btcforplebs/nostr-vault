import Foundation

/// The relay's `wot_links.json`, parsed whole: its sorted follows and, for
/// everyone in the web, which of those follows follow them (indexes into
/// `follows`). `TrustLinks.bridges` reads one entry out of the bytes; the
/// account web needs them all.
struct TrustLinksIndex: Decodable, Equatable, Sendable {
    let follows: [String]
    let links: [String: [Int]]

    static func parse(_ data: Data) -> TrustLinksIndex? {
        try? JSONDecoder().decode(TrustLinksIndex.self, from: data)
    }
}

/// What the account web needs besides the graph: who "you" are on this
/// device and the bar the relay counts against.
struct AccountWebScope: Equatable, Sendable {
    /// Every account on this device (owner, open account, added accounts).
    var owners: Set<String>
    /// Min Followers: how many of your follows must follow someone.
    var minFollowers: Int
    /// The open account's follow list has really loaded. Until it has, the
    /// follows can read empty or short, so the shared web is used as before.
    var followsKnown: Bool
}

/// One account's web (Logen 2026-11-13). The relay builds a single web from
/// every account on the device: all their follows pooled, and the
/// Min Followers count taken across the pool. So someone one follow of the
/// open account plus two follows of another account got in, and read as three
/// hops out from the account on screen. This narrows the relay's web to the
/// open account: you and your accounts, your follows, and anyone at least
/// `minFollowers` of your own follows follow. No engine change: the relay's
/// web still decides who may write to the inbox.
enum AccountWeb {
    /// The relay's cap on a new account's widened web (`thin_web.go`).
    static let newAccountWebCap = 1000

    static func web(saved: Set<String>, follows: Set<String>, links: TrustLinksIndex?, depth: Int?,
                    scope: AccountWebScope) -> Set<String> {
        let shared = TrustMap.web(saved: saved, follows: follows)
        let bar = max(scope.minFollowers, 1)
        // Keep the shared web where this can't tell who is yours: no graph
        // yet (that is just the follows already), the follow list still
        // loading.
        guard !saved.isEmpty, scope.followsKnown else { return shared }
        var web = follows.union(scope.owners)
        switch depth {
        case 2:
            // You and your follows; the relay pooled every account's follows.
            return web
        case 3:
            // An older relay or an unreadable file (no links): keep the shared web.
            guard let links else { return shared }
            let mine = links.follows.map { follows.contains($0) }
            var counts: [String: Int] = [:]
            // The relay sorts each entry, so a repeat sits next to itself.
            for (pubkey, from) in links.links where !web.contains(pubkey) {
                var counted = 0, previous = -1
                for index in from where index != previous && mine.indices.contains(index) {
                    previous = index
                    if mine[index] { counted += 1 }
                }
                if counted > 0 { counts[pubkey] = counted }
            }
            guard follows.count >= bar else {
                // Fewer follows than the bar: the relay widens a new account's
                // web to its follows' follows (newAccountWeb). Do the same from
                // this account's own follows, not the pool's: anyone one of
                // them follows, most followed first, capped like the relay.
                let widened = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map(\.key)
                return web.union(widened.prefix(newAccountWebCap))
            }
            for (pubkey, counted) in counts where counted >= bar {
                web.insert(pubkey)
            }
            return web
        default:
            return shared
        }
    }
}

/// `wot_cache.json` and `wot_links.json` read as one thing (Tron 2011
/// must-fix 2). The relay renames the cache into place and only then writes
/// the links, so a read in between gets a new graph with the last build's
/// links, or none. Keying reloads to the cache alone pinned that until the
/// next rebuild, about a day.
enum WotFiles {
    static func linksURL(beside cacheURL: URL) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent(TrustLinks.fileName)
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Changes when either file is rewritten: the later of the two dates.
    /// nil while there is no cache.
    static func stamp(cacheURL: URL) -> Date? {
        guard let cache = modified(cacheURL) else { return nil }
        return max(cache, modified(linksURL(beside: cacheURL)) ?? cache)
    }

    /// The links on disk belong to the cache on disk: written at or after it.
    /// Below depth 3 there are no links to wait for.
    static func linksCurrent(cacheURL: URL, depth: Int?) -> Bool {
        guard (depth ?? 0) >= 3 else { return true }
        guard let cache = modified(cacheURL), let links = modified(linksURL(beside: cacheURL)) else { return false }
        return links >= cache
    }
}
