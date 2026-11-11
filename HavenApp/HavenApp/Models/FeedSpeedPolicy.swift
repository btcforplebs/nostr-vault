import Foundation

/// The feed-speed rules shared by FeedService and FeedView (Logen 2026-11-02,
/// RESEARCH/NV_FEED_SPEED_AUDIT.md). Plain values only, so they are tested
/// without the services. Feeds are named by `FeedMode.rawValue`.
enum FeedSpeedPolicy {
    static let discovery = "Discovery"
    static let popular = "Popular"

    /// Discover and Popular take the longest to build (a network to walk, a
    /// ranking to compute), so their tab caches are also kept on disk and are
    /// instant on a cold launch. Every other feed stays memory-only.
    static func persistsModeCache(_ mode: String) -> Bool {
        // Catch Up and Underrated are computed the same way as Popular.
        mode == discovery || mode == popular || mode == "Catch Up" || mode == "Underrated"
    }

    /// How old a tab cache may be and still be shown. A persisted one is shown
    /// up to a day old, then topped up (Discover) or recomputed (Popular)
    /// behind it; the rest only for 15 minutes, as before.
    static func modeCacheMaxAge(persisted: Bool) -> TimeInterval {
        persisted ? 24 * 60 * 60 : 15 * 60
    }

    /// One file per account and feed, so accounts never see each other's.
    static func diskModeCacheFileName(cacheKey: String) -> String {
        let safe = cacheKey.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return "feed_tab_cache_\(String(safe)).json"
    }

    /// Whether a tab switch keeps the feed's relay connections. Both feeds
    /// stream from relays through the note pipeline, so the open sockets are
    /// sent CLOSE for the old feed's subscriptions and the new feed's REQ
    /// under a new id (`feedSubId`), instead of being closed and reopened. Anything else (a
    /// side feed, Popular, Music) still closes them: an idle socket would keep
    /// streaming the old feed into a pipeline nobody sees.
    static func keepsFeedSockets(fromStreams: Bool, toStreams: Bool) -> Bool {
        fromStreams && toStreams
    }

    // MARK: - Subscription ids per tab switch

    /// The prefixes the feed's own subscriptions carry before the primary id
    /// (`feed-<generation>-<relay>`): auxiliary mentions, reactions and zaps,
    /// and Global's trusted-authors REQ.
    static let feedSubPrefixes = ["", "wot-", "m-", "rx-", "zaps-in-", "zaps-out-"]

    /// The feed's primary subscription id on a relay for one tab-switch
    /// generation. A kept socket gets a new id after a switch, so frames still
    /// coming in for the old feed can be told apart and dropped (Tron, #1547).
    static func feedSubId(generation: Int, relaySuffix: String) -> String {
        "feed-\(generation)-\(relaySuffix)"
    }

    /// Every id the feed opened on one relay in a generation: what a kept
    /// socket is sent CLOSE for when the feed changes.
    static func feedSubIds(generation: Int, relaySuffix: String) -> [String] {
        let primary = feedSubId(generation: generation, relaySuffix: relaySuffix)
        return feedSubPrefixes.map { $0 + primary }
    }

    /// The generation a feed subscription id was opened in, or nil for an id
    /// that isn't one of the feed's (parent fetches, deletes, the globe).
    static func feedSubGeneration(of subId: String) -> Int? {
        guard let range = subId.range(of: "feed-") else { return nil }
        let prefix = String(subId[..<range.lowerBound])
        guard feedSubPrefixes.contains(prefix) else { return nil }
        let digits = subId[range.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, subId[range.upperBound...].dropFirst(digits.count).first == "-" else { return nil }
        return Int(digits)
    }

    /// The generation after `current`, begun on every tab switch and every
    /// account switch: a socket kept across either must not pass the old
    /// feed's (or the old account's) frames into the new one.
    static func nextFeedSubGeneration(after current: Int) -> Int {
        current == Int.max ? 0 : current + 1
    }

    /// What a note lookup asks for: notes by id (`ids`), or one addressable
    /// event by its kind:author:d coordinate (an naddr quote).
    enum LookupKind { case notes, address }

    /// The sub id for a note lookup. Lookups are often sent on a feed socket
    /// that is already open, so their replies arrive mixed in with the feed's.
    /// Every kind shares one prefix, so the feed socket hands all of them to
    /// the lookup handler (which checks each reply against what was asked
    /// for). naddr lookups used to have their own prefix that only the feed
    /// knew: their replies went into the feed, and the quote card never filled.
    static func lookupSubId(_ kind: LookupKind, suffix: String) -> String {
        "\(lookupSubPrefix)\(kind == .notes ? "t" : "a")-\(suffix)"
    }

    /// A reply on a feed socket that belongs to a lookup, not to the feed.
    static func isLookupReply(subId: String) -> Bool {
        subId.hasPrefix(lookupSubPrefix)
    }

    private static let lookupSubPrefix = "lookup-"

    /// A frame for a feed subscription from an earlier generation: the old
    /// feed, still arriving on a socket kept across the switch. Dropped, or
    /// Global's strangers would land in Discover and its EOSE would end the
    /// new load early.
    static func isStaleFeedSub(_ subId: String, current: Int) -> Bool {
        guard let generation = feedSubGeneration(of: subId) else { return false }
        return generation != current
    }

    /// A finished Popular compute replaces what is on screen, except that an
    /// empty answer never wipes a ranking already showing.
    static func popularReplacesShown(resultCount: Int, showingOld: Bool) -> Bool {
        resultCount > 0 || !showingOld
    }

    /// The placeholder rows show while a feed is loading with nothing to show,
    /// and only until the first relay answers: after that an empty feed shows
    /// its own state instead of rows that look like content on the way.
    static func showsLoadingRows(isLoading: Bool, hasNotes: Bool, relayAnswered: Bool) -> Bool {
        isLoading && !hasNotes && !relayAnswered
    }
}
