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
        mode == discovery || mode == popular
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
    /// re-sent the new REQ (same subscription id per relay, which replaces
    /// the old one) instead of being closed and reopened. Anything else (a
    /// side feed, Popular, Music) still closes them: an idle socket would keep
    /// streaming the old feed into a pipeline nobody sees.
    static func keepsFeedSockets(fromStreams: Bool, toStreams: Bool) -> Bool {
        fromStreams && toStreams
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
