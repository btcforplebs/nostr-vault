import Foundation

/// The order hashtag results show in, in the Search tab and the Vault's
/// search (search plan §1c): the tag you typed first, then by how many of
/// the matched notes carry it, then A-Z. Pure, so MediaLogicTests compiles
/// this same file. Android twin: `data/model/HashtagSearchRank.kt`; web:
/// `net/search.js` hashtags.
enum HashtagSearchRank {
    /// The words a query names tags by: lowercased, `#` dropped.
    static func words(_ query: String) -> [String] {
        query.lowercased()
            .replacingOccurrences(of: "#", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Counts how many items carry each tag. `tags(item)` gives that item's
    /// tags, lowercased; a tag twice on one item counts once.
    static func counts<T>(_ items: [T], tags: (T) -> [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            for tag in Set(tags(item)) { counts[tag, default: 0] += 1 }
        }
        return counts
    }

    /// `counts`' tags in order. Exact means the tag is the whole query or
    /// one of its words ("#bitcoin" and "bitcoin" both make "bitcoin" exact).
    static func order(_ counts: [String: Int], query: String) -> [String] {
        let words = words(query)
        let exact = Set(words).union([words.joined()])
        return counts.keys.sorted { a, b in
            let ea = exact.contains(a), eb = exact.contains(b)
            if ea != eb { return ea }
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return a < b
        }
    }
}
