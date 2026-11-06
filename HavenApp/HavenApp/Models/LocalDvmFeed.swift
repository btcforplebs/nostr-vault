import Foundation

/// The feeds the relay's local DVM computes rather than streams: Popular,
/// Catch Up (the newest post of each person you follow) and Underrated
/// (Popular turned over: people who post less and are known to fewer of your
/// follows, scored against their own usual). haven-go dvm.go,
/// feed_catchup.go, feed_underrated.go. Twin of Android's FeedMode.isLocalDvm.
///
/// Pure Foundation so MediaLogicTests can test it; FeedMode reads it.
enum LocalDvmFeed: String, CaseIterable {
    case popular = "Popular"
    case catchUp = "Catch Up"
    case underrated = "Underrated"

    /// Shown while the relay computes it.
    var loadingStatus: String {
        switch self {
        case .popular: return "Discovering popular notes..."
        case .catchUp: return "Catching up on the people you follow..."
        case .underrated: return "Looking for underrated notes..."
        }
    }

    /// Shown when the answer is empty.
    var emptyStatus: String {
        switch self {
        case .popular: return "No popular notes found"
        case .catchUp: return "Nobody you follow posted in the last two weeks"
        case .underrated: return "No underrated notes found"
        }
    }

    /// Popular and Underrated are scored against the web of trust inside
    /// the relay, which withholds them until the graph is built. Catch Up
    /// reads only your follows.
    var needsTrustGraph: Bool { self != .catchUp }

    /// The follow list Catch Up hands the relay: a JSON array of lowercase
    /// hex pubkeys, sorted, duplicates and anything not a pubkey dropped.
    static func followsJSON(_ pubkeys: some Sequence<String>) -> String {
        let hex = Set(pubkeys.map { $0.lowercased() }.filter(isHexPubkey)).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: hex),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func isHexPubkey(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
