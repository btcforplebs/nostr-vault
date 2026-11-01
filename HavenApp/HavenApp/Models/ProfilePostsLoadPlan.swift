import Foundation

/// The rules for loading a profile's posts when the app knows little about
/// the person (most of the WoT): how long each relay and the relay-list
/// lookup get, which relays to try when they publish no relay list, and
/// when an empty result is worth one more try.
enum ProfilePostsLoadPlan {
    /// Each relay of the load gets this long, from when it is opened, to
    /// answer. A relay found late (their write relays, after the kind 10002
    /// lookup) gets the full time too, instead of what was left of one cap
    /// on the whole load.
    static let relayAnswerTimeout: TimeInterval = 8

    /// How long to wait for the kind 10002 lookup. `fetchRelayList` keeps
    /// each connection 5 s after it connects and clears its own in-flight
    /// mark after 10 s, so an answer can come up to then.
    static let relayListTimeout: TimeInterval = 10

    /// Big public relays most people post to, asked when the person has no
    /// relay list with write relays in it.
    static let noRelayListFallback = [
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.snort.social",
    ]

    /// The relays to add once the lookup is over: none when their write
    /// relays are known (those are asked already), otherwise the fallback
    /// relays not asked yet. `asked` holds `relayKey`s.
    static func fallbackRelays(writeRelays: [String]?, asked: Set<String>) -> [String] {
        if let writeRelays, !writeRelays.isEmpty { return [] }
        return noRelayListFallback.filter { !asked.contains(relayKey($0)) }
    }

    /// The whole load is over with no posts by this person: try once more,
    /// but only when a relay did not finish. Relays drop first connections
    /// and rate-limit bursts often enough that a refusal or a silence is not
    /// proof of an empty profile. When every relay sent EOSE the answer is
    /// complete, and a second load only held "Loading…" (up to about 36 s)
    /// on a profile with no posts.
    static func shouldRetry(postsFound: Int, alreadyRetried: Bool, everyRelayFinished: Bool) -> Bool {
        postsFound == 0 && !alreadyRetried && !everyRelayFinished
    }

    /// One spelling per relay, so "wss://x/" and "wss://X" count once.
    static func relayKey(_ url: String) -> String {
        url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}
