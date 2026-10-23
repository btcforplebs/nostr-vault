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

    /// Up to `ReferralSuggestions.limit` of `person`'s follows, most-followed
    /// first, with their profiles fetched. `exclude`: you and the people you
    /// already follow.
    static func suggestions(for person: Person, exclude: Set<String>) async -> [String] {
        let readers = Array(person.follows.prefix(ReferralSuggestions.listsToRead))
        var lists: [String: [String]] = [:]
        if !readers.isEmpty {
            let events = await NostrService.shared.fetchEvents(
                filter: ["kinds": [3], "authors": readers], from: listRelays, timeout: 8)
            for event in events.sorted(by: { $0.created_at < $1.created_at }) where event.kind == 3 {
                lists[event.pubkey] = ReferralSuggestions.follows(inContactListTags: event.tags) // newest wins
            }
        }
        let picked = ReferralSuggestions.rank(referrerFollows: person.follows, lists: lists,
                                              exclude: exclude.union([person.pubkey]))
        if !picked.isEmpty {
            let profiles = await NostrService.shared.fetchEvents(
                filter: ["kinds": [0], "authors": picked], from: relays)
            NostrService.shared.ingestProfiles(profiles.filter { picked.contains($0.pubkey) })
        }
        return picked
    }
}
