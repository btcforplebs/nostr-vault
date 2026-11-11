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

    /// Shown under the last note: the set is fixed, so there is no next page
    /// and the list stopping is the end of it, not a stall. The view adds the
    /// way to get a new one (pull on iPhone, a button on Mac).
    var endOfListStatus: String {
        switch self {
        case .popular: return "That's what's popular from the last day."
        case .catchUp: return "You're caught up on everyone you follow from the last two weeks."
        case .underrated: return "That's today's underrated list."
        }
    }

    /// The end-of-list footer draws only on a local DVM feed that has notes
    /// and is not loading; an empty feed keeps its own empty state.
    static func showsEndOfList(mode: LocalDvmFeed?, hasNotes: Bool, isLoading: Bool) -> Bool {
        mode != nil && hasNotes && !isLoading
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

/// Why the relay's Underrated answer is empty (haven-go feed_underrated.go
/// underratedEmptyReason): ComputeUnderratedNotesC answers
/// `{"reason": ...}` instead of an empty list. Twin of Android's
/// UnderratedEmptyReason.
enum UnderratedEmptyReason: String, Equatable {
    /// The web is follows only (the wider network was never built): nobody
    /// can be one step out until it is.
    case webIncomplete = "web_incomplete"
    /// The web is whole and still nothing cleared the bar.
    case nothingQualified = "nothing_qualified"
    /// The trust graph is not built yet: the relay withholds the feed.
    case webNotReady = "web_not_ready"

    /// The reason in a relay answer, or nil for a list of notes, an error or
    /// a reason this build doesn't know.
    static func parse(_ json: String) -> UnderratedEmptyReason? {
        guard json.hasPrefix("{"), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["reason"] as? String else { return nil }
        return UnderratedEmptyReason(rawValue: raw)
    }
}

/// Underrated's empty screen: the words and which button, from the reason
/// the relay gave. A follows-only web offers to build the wider network
/// (the Vault's `wider_network` job, ImportJobsService); anything else keeps
/// Refresh Feed. Popular and Catch Up never read this.
struct UnderratedEmptyState: Equatable {
    enum Action: Equatable {
        case refreshFeed
        case buildWiderNetwork
        /// The wider network is being built: shown, not tappable.
        case buildingWiderNetwork
    }

    let title: String
    let subtitle: String
    let action: Action

    static let widerWebTitle = "Underrated needs your wider web"
    static let widerWebSubtitle = "Underrated shows people your follows follow, and your vault only knows your follows so far."
    static let buildTitle = "Build your wider network"
    static let buildingTitle = "Building your wider network…"

    static func of(reason: UnderratedEmptyReason?, building: Bool) -> UnderratedEmptyState {
        guard reason == .webIncomplete || building else {
            return UnderratedEmptyState(
                title: "Nothing underrated yet",
                subtitle: "Underrated shows people your follows follow and you don't, once a few people in your web like, repost or zap them. Check back later.",
                action: .refreshFeed)
        }
        return UnderratedEmptyState(title: widerWebTitle, subtitle: widerWebSubtitle,
                                    action: building ? .buildingWiderNetwork : .buildWiderNetwork)
    }
}
