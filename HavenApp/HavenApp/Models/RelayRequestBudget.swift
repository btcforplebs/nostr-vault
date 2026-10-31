import Foundation

/// How hard the background lookups lean on public relays. relay.damus.io bans,
/// and lists in public, IPs that send it too many requests in 24 h (Tod,
/// 2026-10-31); the iPhone and Mac sent it about 1,200 connections and 2,350
/// REQs a day, most of them from the three lookups below
/// (RESEARCH/NV_DAMUS_REQUEST_BUDGET.md). Damus stays a feed and broadcast
/// relay; it is only taken out of the lookups that fire on every scroll.
enum RelayRequestBudget {
    static let damus = "wss://relay.damus.io"

    /// Asked for profile metadata on top of the Read relays (Android's
    /// `PROFILE_RELAYS`). purplepag.es had every profile tried (jack, ODELL,
    /// fiatjaf; 2026-10-06). offchain.pub dropped: it refuses connections
    /// (2026-10-12). relay.damus.io dropped: one batch every tick was most of
    /// the app's damus traffic (2026-10-31).
    static let profileIndexRelays = [
        "wss://user.kindpag.es",
        "wss://purplepag.es",
    ]

    /// How often queued profile lookups go out as one batch. Was 0.5 s.
    static let profileFlushInterval: TimeInterval = 2
    /// A profile lookup socket nothing has used for this long is closed; the
    /// next batch opens it again.
    static let profileSocketIdle: TimeInterval = 30
    /// A profile REQ is closed after this, answered or not.
    static let profileSubscriptionSeconds: TimeInterval = 5

    /// Live rings ask zap.stream alone: it is where streams are published,
    /// and the only relay that answered for the Live tab (2026-09-05).
    static let liveRingRelays = [LiveChat.streamRelay]
    /// Pause before a live-ring batch goes out. Was 0.6 s.
    static let liveRingBatchDelay: TimeInterval = 3

    /// Missing notes are collected this long before one fetch goes out. Was 0.15 s.
    static let noteFetchWindow: TimeInterval = 1

    /// The last stop for a missing note, after its hints and the author's
    /// relays. relay.nostr.net and relay.fountain.fm found 112 of 172 notes
    /// still missing after the rest on 2026-10-16, the best pair of 20 tried.
    /// A quote in Logen's thread (Plural's, a2f86e95) was on fountain.fm
    /// alone. relay.damus.io dropped (2026-10-31).
    static let fallbackNoteRelays = [
        "wss://nostr.wine",
        "wss://nostr.oxtr.dev",
        "wss://nostr.land",
        "wss://relay.nostrplebs.com",
        "wss://relay.snort.social",
        "wss://relay.primal.net",
        "wss://relay.nostr.net",
        "wss://relay.fountain.fm",
    ]
}
