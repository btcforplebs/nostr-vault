import Foundation

/// Setup's "Who told you about Nostr Vault?" step offers some of the people
/// that person follows. This is how they are picked, the same on Android
/// (ReferralSuggestions.kt): among the referrer's follows, the ones the most
/// of the referrer's other follows also follow come first ("most-followed"),
/// ties in the order the referrer's list has them.
enum ReferralSuggestions {
    /// How many people are offered.
    static let limit = 10
    /// How many of the referrer's follows have their own lists read to count
    /// with: the first ones in the referrer's list. A list can be tens of KB,
    /// so this is what keeps the step cheap on a phone's data.
    static let listsToRead = 150

    /// The p-tagged pubkeys of a kind 3, lowercased, each once, in order.
    static func follows(inContactListTags tags: [[String]]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            let key = tag[1].lowercased()
            guard key.count == 64, key.allSatisfy(\.isHexDigit), seen.insert(key).inserted else { return nil }
            return key
        }
    }

    /// Up to `limit` of `referrerFollows`, most-followed first.
    /// - lists: the follow lists read, by author (only lists by the referrer's
    ///   own follows count; anyone else's are ignored).
    /// - exclude: never offered (you, the referrer, people you already follow).
    static func rank(referrerFollows: [String], lists: [String: [String]], exclude: Set<String>) -> [String] {
        let candidates = referrerFollows.filter { !exclude.contains($0) }
        let following = Set(referrerFollows)
        var counts: [String: Int] = [:]
        for (author, follows) in lists where following.contains(author) {
            for key in Set(follows) where key != author { counts[key, default: 0] += 1 }
        }
        let order = Dictionary(referrerFollows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates
            .sorted { a, b in
                let ca = counts[a, default: 0], cb = counts[b, default: 0]
                return ca != cb ? ca > cb : order[a, default: .max] < order[b, default: .max]
            }
            .prefix(limit)
            .map { $0 }
    }
}
