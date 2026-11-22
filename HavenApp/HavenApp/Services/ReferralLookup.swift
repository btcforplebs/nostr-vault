import Foundation

/// The network half of setup's "Who told you about Nostr Vault?" step: the
/// person's profile and follow list, the lists of the people they follow (to
/// rank them, `ReferralSuggestions`), and the profiles of the ones offered.
/// Reads public profile relays directly: setup runs before the device's relay.
@MainActor
enum ReferralLookup {
    /// Where profiles and follow lists are asked for. purplepag.es keeps
    /// exactly these kinds; the others are the big public relays most lists
    /// also reach.
    static let relays = ["wss://purplepag.es", "wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.nos.social"]
    /// Lists are the heavy read, so they come from two relays only.
    static let listRelays = ["wss://purplepag.es", "wss://relay.primal.net"]

    struct Person {
        let pubkey: String
        /// Whether a kind 0 was found (the card can still show a short npub).
        let hasProfile: Bool
        /// Their follows, in list order.
        let follows: [String]
    }

    /// The referrer's profile (stored into `NostrService.profiles`) and follows.
    static func person(_ pubkey: String) async -> Person {
        let events = await NostrService.shared.fetchEvents(
            filter: ["kinds": [0, 3], "authors": [pubkey]], from: relays)
        let mine = events.filter { $0.pubkey == pubkey }
        NostrService.shared.ingestProfiles(mine)
        let list = mine.filter { $0.kind == 3 }.max { $0.created_at < $1.created_at }
        return Person(pubkey: pubkey,
                      hasProfile: mine.contains { $0.kind == 0 },
                      follows: ReferralSuggestions.follows(inContactListTags: list?.tags ?? []))
    }

    /// What the people step offers: up to `ReferralSuggestions.pool` of the
    /// referrer's follows, closest to the referrer first, and topic chips
    /// from their recent notes.
    struct Suggestions {
        let picks: [ReferralSuggestions.Pick]
        let topics: [(topic: String, people: Set<String>)]
    }

    /// `person`'s follows ranked by their close circle (`ReferralSuggestions`),
    /// with profiles and recent hashtags fetched. `exclude`: you and the
    /// people you already follow.
    static func suggestions(for person: Person, exclude: Set<String>) async -> Suggestions {
        let readers = Array(person.follows.prefix(ReferralSuggestions.listsToRead))
        var lists: [String: [String]] = [:]
        if !readers.isEmpty {
            let events = await NostrService.shared.fetchEvents(
                filter: ["kinds": [3], "authors": readers], from: listRelays, timeout: 8)
            for event in events.sorted(by: { $0.created_at < $1.created_at }) where event.kind == 3 {
                lists[event.pubkey] = ReferralSuggestions.follows(inContactListTags: event.tags) // newest wins
            }
        }
        let picks = ReferralSuggestions.rank(referrer: person.pubkey, referrerFollows: person.follows, lists: lists,
                                             exclude: exclude.union([person.pubkey]))
        guard !picks.isEmpty else { return Suggestions(picks: [], topics: []) }
        let keys = picks.map(\.pubkey)
        // Profiles, the last month of notes and their public interest lists
        // (kind 10015), side by side. The notes' and lists' `t` tags make the
        // topic chips; many people use no hashtags, so either can be empty.
        let since = Int(Date().timeIntervalSince1970) - 30 * 86_400
        async let profiles = NostrService.shared.fetchEvents(
            filter: ["kinds": [0], "authors": keys], from: relays)
        async let notes = NostrService.shared.fetchEvents(
            filter: ["kinds": [1], "authors": keys, "since": since, "limit": 500], from: listRelays)
        async let interests = NostrService.shared.fetchEvents(
            filter: ["kinds": [10015], "authors": keys], from: listRelays)
        let (found, recent, interestLists) = await (profiles, notes, interests)
        NostrService.shared.ingestProfiles(found.filter { keys.contains($0.pubkey) })
        let tagged = (recent + interestLists).map { (author: $0.pubkey, tags: $0.tags) }
        let topics = ReferralSuggestions.topics(notes: tagged, among: keys)
        return Suggestions(picks: picks, topics: topics)
    }
}
