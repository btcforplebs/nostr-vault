package com.nostrvault.data.model

// ---------------------------------------------------------------------------
// Feed mode enums
// ---------------------------------------------------------------------------

enum class FeedMode(val displayName: String) {
    FOLLOWING("Following"),
    DISCOVERY("Discover"),
    GLOBAL("Global"),

    /**
     * Posts in the hashtags you follow (NIP-51 interest list, kind 10015).
     * Like [MUSIC], not a view of the note list: HashtagsFeedViewModel runs
     * its own `#t` REQ and the note subscription is left alone. Declared after
     * Global so a saved picker order gains it right after Global.
     */
    HASHTAGS("Hashtags"),
    POPULAR("Popular"),
    MEDIA("Media"),

    /**
     * diVines: full-screen looping short videos, one per page. Like [LIVE],
     * not a view of the note list: ReelsFeedService runs its own queries
     * (diVine's kind-34236 videos), and the note subscription idles while this
     * mode is showing.
     */
    REELS("diVines"),

    /**
     * Long-form articles (kind 30023). The events were already arriving — the
     * feed subscription has asked for kind 30023 all along and the dashboard
     * counts them — so this mode is a lens on what the relay already holds,
     * not a new fetch.
     */
    ARTICLES("Articles"),

    /**
     * Recipes: the same kind-30023 long-form events, tagged for zap.cooking.
     * A separate mode rather than a filter chip because a recipe list is what
     * you want when you want a recipe, and articles and recipes read nothing
     * alike even though the wire format is identical.
     */
    RECIPES("Recipes"),

    /**
     * NIP-53 live streams (kind 30311). Unlike every other mode this is not a
     * view of the note list — live events are replaceable announcements
     * fetched fresh each time, because one that ended two minutes ago still
     * says "live" in anything cached.
     */
    LIVE("Live"),

    /**
     * Marketplace: NIP-15 products/auctions and NIP-99 classifieds, as in the
     * MyNostrSpace marketplace. Like Live, not a view of the note list —
     * MarketplaceFeedService fetches listings from the marketplace relays.
     */
    MARKETPLACE("Marketplace"),

    /**
     * NIP-88 polls (kind 1068). A view of the note list like [ARTICLES]: the
     * primary REQ asks for polls only, scoped Following / Global.
     */
    POLLS("Polls"),

    /**
     * Wavlake music: trending and search, played in the background by
     * MusicPlaybackService. Not a view of the note list either; the note
     * subscription idles while this mode is showing.
     */
    MUSIC("Music"),
}

enum class MediaFeedMode(val displayName: String) {
    FOLLOWING("Following"),
    GLOBAL("Global"),
}

enum class PopularFilter(val displayName: String) {
    ALL("All"),
    FOLLOWS("Follows"),
    NON_FOLLOWS("Non-Follows"),
}
