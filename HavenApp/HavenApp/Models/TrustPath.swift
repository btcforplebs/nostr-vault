import Foundation

/// How a post's author reaches you through your Web of Trust, for the Trust
/// Path card in Event Info. The relay's trust graph (`wot_cache.json`) is only
/// a yes/no set, so the "bridge" people — those you follow who follow the
/// author — are rebuilt from a few signed follow lists (kind 3) on demand.
struct TrustPath: Equatable {
    enum Reach: Equatable {
        /// The author is you.
        case you
        /// You follow the author (1 hop).
        case follow
        /// Someone you follow follows the author (2 hops).
        case bridged
        /// In the relay's trust graph, but no bridge turned up in the lists
        /// the relays sent back.
        case web
        /// Not in your trust graph, and no bridge turned up either. Only as
        /// sure as the relays asked: a list they lack can't be seen.
        case outside
        /// No trust graph loaded yet, so "outside" can't be claimed.
        case unknown
    }

    let reach: Reach
    /// Up to `shownBridges` people you follow who follow the author, sorted by
    /// key so a cached answer always draws in the same order.
    let bridges: [String]
    /// More bridges were found than are shown. Not a count: an exact count
    /// would mean downloading every follow list.
    let hasMore: Bool

    /// Avatars that fit on the card.
    static let shownBridges = 5
    /// Follow lists asked for per filter: one more than shown, so "+ more"
    /// can be known without fetching everything. Each list is someone's whole
    /// follow list (~90 KB at 1,000 follows), so this is the cost knob.
    static let listsPerFilter = shownBridges + 1

    /// Builds the path from follow lists relays returned. Lists signed by
    /// anyone you don't follow, or that don't tag the author, are ignored, so
    /// a relay can't make up a bridge; only each signer's newest list counts.
    /// A relay could still replay an old signed list (the `#p` filter never
    /// fetches a newer one without the author). Signatures are checked by the
    /// caller.
    static func resolve(author: String, me: String, follows: Set<String>,
                        trustGraph: Set<String>, contactLists: [[String: Any]]) -> TrustPath {
        if author == me { return TrustPath(reach: .you, bridges: [], hasMore: false) }

        var newest: [String: (createdAt: Int, tagsAuthor: Bool)] = [:]
        for list in contactLists {
            guard list["kind"] as? Int == 3,
                  let signer = list["pubkey"] as? String,
                  signer != author, signer != me, follows.contains(signer),
                  let tags = list["tags"] as? [[String]]
            else { continue }
            let createdAt = (list["created_at"] as? Int) ?? 0
            if let seen = newest[signer], seen.createdAt >= createdAt { continue }
            let tagsAuthor = tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == author }
            newest[signer] = (createdAt, tagsAuthor)
        }
        let sorted = newest.filter(\.value.tagsAuthor).keys.sorted()
        let shown = Array(sorted.prefix(shownBridges))
        let more = sorted.count > shownBridges

        let reach: Reach
        if follows.contains(author) {
            reach = .follow
        } else if !shown.isEmpty {
            reach = .bridged
        } else if trustGraph.isEmpty {
            reach = .unknown
        } else {
            reach = trustGraph.contains(author) ? .web : .outside
        }
        return TrustPath(reach: reach, bridges: shown, hasMore: more)
    }

    /// The follow-list filters to ask for: your follows in chunks, each tagging
    /// the author, each capped at `listsPerFilter`. relay.primal.net and
    /// relay.damus.io both took 1,015 authors in one filter (checked
    /// 2026-10-07), so most accounts send a single filter.
    static func filters(author: String, follows: [String], chunkSize: Int = 1000) -> [[String: Any]] {
        let authors = follows.filter { $0 != author }
        return stride(from: 0, to: authors.count, by: chunkSize).map { start in
            let chunk = Array(authors[start..<min(start + chunkSize, authors.count)])
            return ["kinds": [3], "authors": chunk, "#p": [author], "limit": listsPerFilter]
        }
    }
}
