import Foundation

/// Discovery design B, phone side: a desktop Vault fetches the recent posts
/// of each account's top 500 distant connections and hands them to the
/// phone's own feed store over the mesh (engine `trustrank.Distant`,
/// `copyv2_distant.go`). Discover asks that local store for the distant
/// people the reach bar lets in, highest score first, as many as the Vault
/// fetches for. External relays keep today's request. Android twin:
/// `data/model/DistantPostAuthors.kt`.
enum DistantPostAuthors {
    /// The engine's `trustrank.DistantMax`: more would ask the local store
    /// for people whose posts never reach the phone.
    static let max = 500

    /// `distant` (who the bar admits three hops out and further) less
    /// `muted`, ordered by score in `copy`, highest first, ties by key, at
    /// most `max`. Mutes go before the cut, as the engine's do, so a muted
    /// person never takes the place of one the Vault fetches for.
    static func pick(_ distant: Set<String>, copy: TrustRankCopy?, muted: Set<String> = []) -> [String] {
        guard let copy, !distant.isEmpty else { return [] }
        let asked = distant.subtracting(muted)
        let ranked = asked.compactMap { pk in copy.people[pk].map { (pk, $0.score) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return ranked.prefix(max).map(\.0)
    }

    /// The second filter of Discover's request to the local feed store:
    /// `filter` (kinds, since, limit, until) for `authors` instead. nil when
    /// there is nobody to ask for.
    static func localFilter(_ filter: [String: Any], authors: [String]) -> [String: Any]? {
        guard !authors.isEmpty else { return nil }
        var out = filter
        out["authors"] = authors
        return out
    }
}
