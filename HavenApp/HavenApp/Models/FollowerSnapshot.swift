import Foundation

// MARK: - Follower ledger model

/// One owner's followers from the relay's follower ledger (`GetFollowersC`).
/// The relay already sorts them newest follow first and puts each in a tier.
struct FollowerSnapshot: Decodable {
    struct Counts: Decodable {
        let trusted: Int
        let others: Int
        let spam: Int
        let unfollowed: Int
    }

    struct Entry: Decodable, Identifiable {
        let pubkey: String
        let tier: String
        let following: Bool
        /// Followed before the ledger started: not news.
        let existing: Bool
        let followedAt: Int64
        /// Follow starts we saw; more than one means they left and came back.
        let follows: Int
        /// Their latest list time. For a follow that predates the ledger it is
        /// the only "when" there is, so it orders those.
        let listAt: Int64

        var id: String { pubkey }
        var isSpam: Bool { tier == "spam" }
        var isReturning: Bool { follows > 1 }
        /// A follow we watched happen: a first follow since the ledger began,
        /// or a comeback. A refollow bot republishing its list is neither.
        var isNews: Bool { following && !isSpam && (!existing || isReturning) }
        var followedDate: Date { Date(timeIntervalSince1970: TimeInterval(followedAt)) }

        enum CodingKeys: String, CodingKey {
            case pubkey, tier, following, existing, follows
            case followedAt = "followed_at"
            case listAt = "list_at"
        }
    }

    let counts: Counts
    let followers: [Entry]

    /// Current followers, spam left out, newest first: follows we watched
    /// happen (the relay already sorts them newest first), then everyone who
    /// followed before tracking began, newest list first.
    var current: [Entry] {
        let current = followers.filter { $0.following && !$0.isSpam }
        let watched = current.filter(\.isNews)
        let earlier = current.filter { !$0.isNews }.sorted { $0.listAt > $1.listAt }
        return watched + earlier
    }

    /// The page's list. In your web is the default; the ··· "Outside your
    /// web" shows the rest (Logen 2026-11-14), spam never. `isOutside` is
    /// the Notes page's one rule (`ContentFilter.isOutside`) with the
    /// ledger owner's own web, so it fails closed: with no graph yet only
    /// follows and whitelisted people are in.
    func entries(for filter: FollowersFilter, isOutside: (String) -> Bool) -> [Entry] {
        FollowersFilter.pick(current, filter, pubkey: \.pubkey, isOutside: isOutside)
    }

    /// Follows that are news for the red dot, the Vault's follow lines and
    /// the dashboard's +N: watched happen, and only from inside your web.
    func news(isOutside: (String) -> Bool) -> [Entry] {
        current.filter { $0.isNews && !isOutside($0.pubkey) }
    }
}

/// The Followers page's two lists, split like the Notes page: your web by
/// default, the rest behind the ··· menu. New was folded into the default
/// list (the newest come first in it anyway).
enum FollowersFilter {
    case inWeb
    case outside

    /// `list` kept in order, cut to this side of the web.
    static func pick<T>(_ list: [T], _ filter: FollowersFilter, pubkey: (T) -> String,
                        isOutside: (String) -> Bool) -> [T] {
        list.filter { isOutside(pubkey($0)) == (filter == .outside) }
    }
}
