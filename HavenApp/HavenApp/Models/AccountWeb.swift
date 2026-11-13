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
            // An older relay or an unreadable file (no links), or fewer
            // follows than the bar (the relay widens a new account's web on
            // purpose, newAccountWeb): keep the shared web.
            guard let links, follows.count >= bar else { return shared }
            let mine = links.follows.map { follows.contains($0) }
            // The relay sorts each entry, so a repeat sits next to itself.
            for (pubkey, from) in links.links where !web.contains(pubkey) {
                var counted = 0, previous = -1
                for index in from where index != previous && mine.indices.contains(index) {
                    previous = index
                    guard mine[index] else { continue }
                    counted += 1
                    if counted >= bar {
                        web.insert(pubkey)
                        break
                    }
                }
            }
            return web
        default:
            return shared
        }
    }
}
