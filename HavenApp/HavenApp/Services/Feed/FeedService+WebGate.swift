import Foundation

extension FeedService {
    /// The open account's gate (`WebGate`): its own web and the hop past it,
    /// fail-closed (never the pooled web of every account on the device), with
    /// its blocks and mute list. Every feed filters through this.
    var feedGate: WebGate.Web {
        let config = ConfigService.shared
        return trustedWebMemo.gate(saved: wotPubkeys, follows: followedPubkeys, scope: accountWebScope,
                                   whitelist: config.whitelistedHexPubkeys,
                                   blocked: config.activeAccountBlockedHexPubkeys, mutes: MuteListStore.shared.active)
    }

    /// How far `mode` reaches: Everyone for a Global list with the shield
    /// off, else the feed's Reach setting (`FeedReach`).
    func reach(for mode: FeedMode, globalLike: Bool) -> WebGate.Reach {
        let config = ConfigService.shared.config
        if globalLike && config.globalShowsEveryone { return .everyone }
        return FeedReach.reach(for: mode, settings: config.feedReach)
    }

    /// The current feed's reach.
    var currentReach: WebGate.Reach { reach(for: feedMode, globalLike: isGlobalLikeMode) }
}
