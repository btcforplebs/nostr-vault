import Foundation

/// The count on the iPad feed header's Filter button: how many of the
/// current feed's filter settings are not at their default. Nil means the
/// feed has no such setting, so it can't count. Pure, so the rule is tested
/// (MediaLogicTests/FeedFilterBadgeTests).
struct FeedFilterBadge: Equatable {
    /// Following (true) or Global; nil for feeds without the pair.
    var followingScope: Bool?
    /// The scope a feed opens on. Every feed opens on Following today.
    var defaultFollowingScope = true
    /// Global's Everyone (off = Web of Trust, the default).
    var everyone: Bool?
    /// Global's picked languages (none = all, the default).
    var languageCount: Int?
    var autoLoad: Bool?
    var reposts: Bool?
    var replies: Bool?
    /// Polls: only open or only closed (both is the default).
    var pollStatusNarrowed: Bool?
    /// Popular: only follows or only non-follows (everyone is the default).
    var popularNarrowed: Bool?
    var ranks: Bool?

    /// A new install's settings, so the badge can't drift from them.
    private static let defaults = HavenConfig()
    static let defaultAutoLoad = defaults.autoLoadNewPosts
    static let defaultReposts = defaults.showReposts
    static let defaultReplies = defaults.showReplies
    static let defaultEveryone = defaults.globalShowsEveryone

    var count: Int {
        var n = 0
        if let s = followingScope, s != defaultFollowingScope { n += 1 }
        if let v = everyone, v != Self.defaultEveryone { n += 1 }
        if let c = languageCount, c > 0 { n += 1 }
        if let v = autoLoad, v != Self.defaultAutoLoad { n += 1 }
        if let v = reposts, v != Self.defaultReposts { n += 1 }
        if let v = replies, v != Self.defaultReplies { n += 1 }
        if pollStatusNarrowed == true { n += 1 }
        if popularNarrowed == true { n += 1 }
        if ranks == true { n += 1 }
        return n
    }

    /// "Filter", or "Filter, 2 changed" for VoiceOver.
    var accessibilityLabel: String {
        count == 0 ? "Filter" : "Filter, \(count) changed"
    }
}
