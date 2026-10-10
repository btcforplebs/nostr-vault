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
    /// Every bridge known, sorted by key: the globe traces all of them.
    /// `bridges` is its first `shownBridges`.
    var all: [String] = []

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

        return resolve(author: author, follows: follows, trustGraph: trustGraph,
                       bridges: allBridges(author: author, me: me, follows: follows, contactLists: contactLists))
    }

    /// The path from bridges already known, e.g. from `TrustLinks`, sorted by key.
    static func resolve(author: String, follows: Set<String>, trustGraph: Set<String>,
                        bridges sorted: [String]) -> TrustPath {
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
        return TrustPath(reach: reach, bridges: shown, hasMore: more, all: sorted)
    }

    /// Every bridge in `contactLists`, sorted by key, by the same rules as
    /// `resolve`. The map uses it to light all of them, not just the card's 5.
    static func allBridges(author: String, me: String, follows: Set<String>,
                           contactLists: [[String: Any]]) -> [String] {
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
        return newest.filter(\.value.tagsAuthor).keys.sorted()
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

/// Who follows whom inside your web, from the relay's `wot_links.json`. The
/// relay's WoT rebuild downloads every follow's list anyway and saves, for
/// everyone in the web, which of your follows follow them, as indexes into
/// its sorted follows: `{"follows":[…],"links":{"<pubkey>":[0,7,…],…}}`.
/// Reading that answers a bridge with no relay round trip and no cap.
enum TrustLinks {
    static let fileName = "wot_links.json"

    /// The people in `current` who follow `author`, sorted by key. nil when
    /// the file has no entry for them, so the caller can still ask relays.
    /// Someone unfollowed since the rebuild is left out.
    ///
    /// A large web is several MB and only one entry is ever needed, so this
    /// finds it in the bytes instead of parsing the whole file. Keys are hex
    /// pubkeys and the relay writes compact JSON, so `"<author>":[` is exact.
    static func bridges(in data: Data, of author: String, me: String, current: Set<String>) -> [String]? {
        guard !author.isEmpty, author.allSatisfy(\.isHexDigit),
              let follows = slice(of: Data(#""follows":["#.utf8), closing: UInt8(ascii: "]"), in: data, after: data.startIndex)
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String] }),
              let links = data.range(of: Data(#""links":{"#.utf8)),
              let entry = slice(of: Data("\"\(author)\":[".utf8), closing: UInt8(ascii: "]"), in: data, after: links.upperBound)
        else { return nil }
        let found = String(decoding: entry.dropFirst().dropLast(), as: UTF8.self)
            .split(separator: ",")
            .compactMap { Int($0).flatMap { follows.indices.contains($0) ? follows[$0] : nil } }
            .filter { $0 != author && $0 != me && current.contains($0) }
        return found.isEmpty ? nil : Array(Set(found)).sorted()
    }

    /// From the `[` that ends `key` through the next `closing`.
    private static func slice(of key: Data, closing: UInt8, in data: Data, after start: Data.Index) -> Data? {
        guard let found = data.range(of: key, in: start..<data.endIndex),
              let end = data[found.upperBound...].firstIndex(of: closing)
        else { return nil }
        return data[(found.upperBound - 1)...end]
    }
}
