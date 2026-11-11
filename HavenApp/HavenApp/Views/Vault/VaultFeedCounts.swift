import Combine
import Foundation

/// The two FeedService numbers the Vault shows: how many people you follow
/// and how big your web of trust is.
///
/// The Vault used to watch FeedService whole. FeedService publishes on every
/// note, thread parent and relay state change, so the whole Vault screen (and
/// the media grid inside it) rebuilt on updates it never shows. This model
/// republishes only when one of the two counts actually changes.
@MainActor
final class VaultFeedCounts: ObservableObject {
    @Published private(set) var follows = 0
    @Published private(set) var wot = 0

    init(feedService: FeedService = .shared) {
        // `@Published` emits in willSet, so map the new value, not the service.
        feedService.$followedPubkeys
            .map(\.count)
            .removeDuplicates()
            .assign(to: &$follows)
        feedService.$wotPubkeys
            .map(\.count)
            .removeDuplicates()
            .assign(to: &$wot)
    }
}
