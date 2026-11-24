import Foundation

/// What each feed relay's live primary REQ was last sent with: the author
/// set and the distant authors of Discover's second filter
/// (`desiredDistantAuthors`). One entry per relay key, so forgetting a relay
/// forgets both lists: a distant list left behind could make the drift
/// check re-send a REQ that was already in sync.
///
/// An absent entry means no live primary subscription exists there (e.g. the
/// send was skipped because the follow set was empty), which
/// `resubscribePrimaryIfNeeded()` always treats as drift.
struct FeedSubscriptionLedger {
    struct Entry: Equatable {
        var authors: [String]
        var distant: [String]
    }

    private var byRelay: [String: Entry] = [:]

    subscript(key: String) -> Entry? {
        byRelay[key]
    }

    mutating func record(_ key: String, authors: [String], distant: [String]) {
        byRelay[key] = Entry(authors: authors, distant: distant)
    }

    mutating func forget(_ key: String) {
        byRelay[key] = nil
    }

    mutating func forgetAll() {
        byRelay.removeAll()
    }

    /// True when `key`'s live REQ already asks for `authors` (any order) and
    /// for exactly `distant` (ranked order).
    func isInSync(_ key: String, authors: [String], distant: [String]) -> Bool {
        guard let entry = byRelay[key] else { return false }
        return Set(entry.authors) == Set(authors) && entry.distant == distant
    }
}
