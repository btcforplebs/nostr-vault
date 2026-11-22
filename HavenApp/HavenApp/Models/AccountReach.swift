import Foundation

/// One account's own "Who Can Reach You": its Follow Distance level (1 only
/// you, 2 the people you follow, 3 the people they follow too) and the
/// Minimum Followers bar of level 3. The relay builds each account's web
/// from that account's own follows at this level (haven-go pkg/wot).
struct AccountReach: Codable, Equatable {
    var depth: Int
    var minFollowers: Int

    static let minFollowersRange = 0...100

    /// Held to what the screen offers and the relay runs.
    var clamped: AccountReach {
        AccountReach(depth: RelayAccessLimits.clampedFollowDistance(depth),
                     minFollowers: min(max(minFollowers, Self.minFollowersRange.lowerBound),
                                       Self.minFollowersRange.upperBound))
    }
}
