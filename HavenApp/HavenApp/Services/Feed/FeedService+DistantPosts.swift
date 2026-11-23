import Foundation

extension FeedService {
    /// Discover's second filter, on the request to this device's own feed
    /// store only: the distant connections' posts a desktop Vault handed
    /// over the mesh (`DistantPostAuthors`). External relays are not asked
    /// for them. nil for every other feed and relay.
    func distantPostsFilter(_ filter: [String: Any], label: String) -> [String: Any]? {
        guard feedMode == .discovery, let local = localFeedURL, label == local.absoluteString else { return nil }
        return DistantPostAuthors.localFilter(filter, authors: DiscoveryReachStore.shared.localDistantAuthors)
    }
}
