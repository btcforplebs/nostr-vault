import Foundation

extension FeedService {
    /// Discover's second filter, on the request to this device's own feed
    /// store only: the distant connections' posts a desktop Vault handed
    /// over the mesh (`DistantPostAuthors`). External relays are not asked
    /// for them. nil for every other feed and relay.
    func distantPostsFilter(_ filter: [String: Any], label: String) -> [String: Any]? {
        DistantPostAuthors.localFilter(filter, authors: desiredDistantAuthors(forRelayKey: label))
    }

    /// The distant people the primary request to `key` should ask for: the
    /// reach bar's list on the local feed store in Discover, [] everywhere
    /// else. `resubscribePrimaryIfNeeded` re-sends when it differs from
    /// `subscribedFeeds`.
    func desiredDistantAuthors(forRelayKey key: String) -> [String] {
        guard feedMode == .discovery, let local = localFeedURL, key == local.absoluteString else { return [] }
        return DiscoveryReachStore.shared.localDistantAuthors
    }
}
