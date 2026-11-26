import Foundation

/// Setup's "Who told you about Nostr Vault?" step offers people around the
/// person who told you. This is how they are picked. Android's twin
/// (ReferralSuggestions.kt) still ranks by the overall count until its lane.
///
/// Ranked by **who the referrer interacts with most** (Logen 2026-11-22: the
/// close-circle list still read as the most-followed accounts): replies,
/// mentions, reposts, reactions and zaps, both ways, from their recent
/// activity (`interactions`). Offered from the referrer's follows **and**
/// followers. Ties go to the close circle (mutuals of the referrer, setup
/// screens r3), then to how many of the referrer's follows follow them, then
/// to people who follow each other with the referrer, then to list order.
enum ReferralSuggestions {
    /// How many are ranked and listed (a scrolling list), so a topic chip
    /// still has people to show.
    static let pool = 60
    /// How many of the referrer's follows have their own lists read to count
    /// with: the first ones in the referrer's list. A list can be tens of KB,
    /// so this is what keeps the step cheap on a phone's data.
    static let listsToRead = 150
    /// How many of the referrer's followers are read (their kind 3 names the
    /// referrer). Newest lists first; same data cost as `listsToRead`.
    static let followersToRead = 150
    /// How many of the referrer's recent events (and events tagging them) are
    /// read to count interactions.
    static let activityToRead = 500
    /// At most this many topic chips.
    static let topicLimit = 6

    /// How a person is tied to the referrer by their follow lists.
    enum Relation: Equatable {
        /// The referrer follows them.
        case follows
        /// They follow the referrer.
        case follower
        /// Both.
        case mutual
    }

    struct Pick: Equatable {
        let pubkey: String
        /// How many of the referrer's close circle follow them.
        let close: Int
        /// The weighted count of interactions with the referrer (`weight`).
        var interactions: Int = 0
        var relation: Relation = .follows
    }

    /// An event read to count interactions: its author, kind and tags.
    typealias Activity = (author: String, kind: Int, tags: [[String]])

    /// Follows a join needs before the # step: the referrer and 4 of their
    /// people, so the guide's web of trust (5) is built at setup (Logen
    /// 2026-11-26 70edd8f4). Android: ReferralSuggestions.followGoal.
    static let followGoal = 5

    /// How many more of the offered people must be ticked before Follow
    /// works: 0 once the referrer plus `picked` reach `followGoal`. With
    /// fewer than that offered, any number goes (the guide then browses
    /// Discover with the meter, FillYourFeedGuide.afterIntro).
    static func picksStillNeeded(picked: Int, offered: Int) -> Int {
        let needed = followGoal - 1
        guard offered >= needed else { return 0 }
        return max(0, needed - picked)
    }

    /// What one interaction is worth, by kind: a zap, a reply or mention, a
    /// repost, a reaction. Each event counts once per person it tags.
    static func weight(kind: Int) -> Int {
        switch kind {
        case 9735: return 4
        case 1: return 3
        case 6, 16: return 2
        case 7: return 1
        default: return 0
        }
    }

    /// Who the referrer interacts with, both ways, weighted (`weight`):
    /// - the referrer's own notes, reposts and reactions: everyone they tag;
    /// - others' notes, reposts and reactions that tag the referrer: their author;
    /// - zap receipts: the other side, when the referrer sent (`P`, or the
    ///   zap request's pubkey) or got (`p`) the zap.
    static func interactions(referrer: String, activity: [Activity]) -> [String: Int] {
        let referrer = referrer.lowercased()
        var score: [String: Int] = [:]
        func add(_ key: String, _ w: Int) {
            let key = key.lowercased()
            guard key != referrer, key.count == 64, key.allSatisfy(\.isHexDigit) else { return }
            score[key, default: 0] += w
        }
        for event in activity {
            let w = weight(kind: event.kind)
            guard w > 0 else { continue }
            let tagged = Set(event.tags.compactMap { $0.count >= 2 && $0[0] == "p" ? $0[1].lowercased() : nil })
            if event.kind == 9735 {
                guard let sender = zapSender(event.tags)?.lowercased() else { continue }
                if sender == referrer { tagged.forEach { add($0, w) } }
                else if tagged.contains(referrer) { add(sender, w) }
            } else if event.author.lowercased() == referrer {
                tagged.forEach { add($0, w) }
            } else if tagged.contains(referrer) {
                add(event.author, w)
            }
        }
        return score
    }

    /// The zap's sender: the receipt's `P` tag, else the pubkey of the zap
    /// request in its `description`.
    static func zapSender(_ tags: [[String]]) -> String? {
        if let p = tags.first(where: { $0.count >= 2 && $0[0] == "P" })?[1] { return p }
        guard let json = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = json.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return request["pubkey"] as? String
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

    /// Up to `pool` of the referrer's follows and followers, the ones they
    /// interact with most first.
    /// - lists: the follow lists read, by author (only lists by the referrer's
    ///   own follows count; anyone else's are ignored).
    /// - followers: people whose follow list names the referrer.
    /// - interactions: `interactions(referrer:activity:)`.
    /// - exclude: never offered (you, the referrer, people you already follow).
    static func rank(referrer: String, referrerFollows: [String], followers: [String] = [],
                     interactions: [String: Int] = [:], lists: [String: [String]],
                     exclude: Set<String>, limit: Int = pool) -> [Pick] {
        let referrer = referrer.lowercased()
        let following = Set(referrerFollows)
        let followedBy = Set(followers)
        var seen = Set<String>()
        let candidates = (referrerFollows + followers).filter {
            $0 != referrer && !exclude.contains($0) && seen.insert($0).inserted
        }
        let close = closeCircle(referrer: referrer, referrerFollows: referrerFollows, lists: lists)
        var all: [String: Int] = [:], near: [String: Int] = [:]
        for (author, follows) in lists where following.contains(author) {
            let isClose = close.contains(author)
            for key in Set(follows) where key != author {
                all[key, default: 0] += 1
                if isClose { near[key, default: 0] += 1 }
            }
        }
        let order = Dictionary(candidates.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Mutual: the referrer follows them, and they follow the referrer by
        // the followers read or by their own list read for the close circle.
        func both(_ key: String) -> Bool {
            following.contains(key) && (followedBy.contains(key) || close.contains(key))
        }
        return candidates
            .sorted { a, b in
                let ia = interactions[a, default: 0], ib = interactions[b, default: 0]
                if ia != ib { return ia > ib }
                let na = near[a, default: 0], nb = near[b, default: 0]
                if na != nb { return na > nb }
                let ca = all[a, default: 0], cb = all[b, default: 0]
                if ca != cb { return ca > cb }
                if both(a) != both(b) { return both(a) }
                return order[a, default: .max] < order[b, default: .max]
            }
            .prefix(limit)
            .map { key in
                Pick(pubkey: key, close: near[key, default: 0], interactions: interactions[key, default: 0],
                     relation: both(key) ? .mutual : (following.contains(key) ? .follows : .follower))
            }
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
