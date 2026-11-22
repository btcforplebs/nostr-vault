import Foundation

/// Setup's "Who told you about Nostr Vault?" step offers some of the people
/// that person follows. This is how they are picked. Android's twin
/// (ReferralSuggestions.kt) still ranks by the overall count until its lane.
///
/// Ranked by the referrer's **close circle**, not by fame (setup screens r3,
/// Logen 2026-11-22): the close circle is the referrer's mutuals, their
/// follows whose own list follows the referrer back. A follow comes first
/// when more of that circle follow them too. Ties go to the one more of all
/// the referrer's follows follow, then to the referrer's list order. With no
/// mutual found, the close count is 0 for everyone and the overall count
/// decides, as before.
enum ReferralSuggestions {
    /// How many people are offered with no topic picked.
    static let limit = 10
    /// How many are ranked and kept, so a topic chip still has people to show.
    static let pool = 30
    /// How many of the top ones start ticked.
    static let preTicked = 7
    /// How many of the referrer's follows have their own lists read to count
    /// with: the first ones in the referrer's list. A list can be tens of KB,
    /// so this is what keeps the step cheap on a phone's data.
    static let listsToRead = 150
    /// At most this many topic chips.
    static let topicLimit = 6

    struct Pick: Equatable {
        let pubkey: String
        /// How many of the referrer's close circle follow them.
        let close: Int
    }

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

    /// The referrer's mutuals among the lists read: follows of theirs whose
    /// list has the referrer in it.
    static func closeCircle(referrer: String, referrerFollows: [String], lists: [String: [String]]) -> Set<String> {
        let referrer = referrer.lowercased()
        return Set(referrerFollows.filter { lists[$0]?.contains(referrer) == true })
    }

    /// Up to `pool` of `referrerFollows`, closest to the referrer first.
    /// - lists: the follow lists read, by author (only lists by the referrer's
    ///   own follows count; anyone else's are ignored).
    /// - exclude: never offered (you, the referrer, people you already follow).
    static func rank(referrer: String, referrerFollows: [String], lists: [String: [String]],
                     exclude: Set<String>, limit: Int = pool) -> [Pick] {
        let candidates = referrerFollows.filter { !exclude.contains($0) }
        let following = Set(referrerFollows)
        let close = closeCircle(referrer: referrer, referrerFollows: referrerFollows, lists: lists)
        var all: [String: Int] = [:], near: [String: Int] = [:]
        for (author, follows) in lists where following.contains(author) {
            let isClose = close.contains(author)
            for key in Set(follows) where key != author {
                all[key, default: 0] += 1
                if isClose { near[key, default: 0] += 1 }
            }
        }
        let order = Dictionary(referrerFollows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates
            .sorted { a, b in
                let na = near[a, default: 0], nb = near[b, default: 0]
                if na != nb { return na > nb }
                let ca = all[a, default: 0], cb = all[b, default: 0]
                return ca != cb ? ca > cb : order[a, default: .max] < order[b, default: .max]
            }
            .prefix(limit)
            .map { Pick(pubkey: $0, close: near[$0, default: 0]) }
    }

    /// Topic chips for the people offered: the hashtags (`t` tags) the most
    /// of them used in their recent notes or interest lists, each counted once per person, and
    /// only when at least two of them used it. Returns each topic with who
    /// used it, most-shared first, then by name.
    /// - notes: (author, tags) of the notes read.
    static func topics(notes: [(author: String, tags: [[String]])], among people: [String],
                       limit: Int = topicLimit) -> [(topic: String, people: Set<String>)] {
        let wanted = Set(people)
        var users: [String: Set<String>] = [:]
        for note in notes where wanted.contains(note.author) {
            for tag in note.tags where tag.count >= 2 && tag[0] == "t" {
                let topic = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
                guard (2...24).contains(topic.count), !topic.allSatisfy(\.isNumber) else { continue }
                users[topic, default: []].insert(note.author)
            }
        }
        return users.filter { $0.value.count >= 2 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .prefix(limit)
            .map { (topic: $0.key, people: $0.value) }
    }
}
