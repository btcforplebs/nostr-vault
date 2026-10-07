import Foundation

/// Finds and caches the Trust Path for an author. Runs only when Event Info
/// opens, never while scrolling: a few follow lists, then the answer is cached
/// for the rest of the session.
@MainActor
final class TrustPathService {
    static let shared = TrustPathService()

    private var cache: [String: TrustPath] = [:]
    private var inFlight: [String: Task<(TrustPath, Bool), Never>] = [:]
    /// Public relays tried before giving up on finding more bridges.
    private static let maxRelays = 3

    func path(for author: String) async -> TrustPath {
        let me = ConfigService.shared.activeAccountHexPubkey
        let feed = FeedService.shared
        let follows = feed.followedPubkeys
        let trustGraph = feed.relayTabTrustedPubkeys()
        // The whole follow set and whether the graph is loaded are in the key,
        // so a follow, an unfollow, or the graph arriving gives a fresh answer.
        let key = "\(me)|\(author)|\(Set(follows).hashValue)|\(trustGraph.isEmpty)"
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value.0 }

        let task = Task { @MainActor () -> (TrustPath, Bool) in
            var lists: [[String: Any]] = []
            var anyRelayAnswered = author == me || follows.isEmpty
            if !anyRelayAnswered {
                // Your own relays (this device, the Mac) only keep events from
                // you and your whitelist, so they never hold a follow's list.
                let config = ConfigService.shared.config
                let own: Set<String> = [config.nostrURL, config.macRelayWssURL]
                let feedRelays = config.activeFeedRelays.isEmpty
                    ? RelayConfiguration.fallbackBroadcastRelays : config.activeFeedRelays
                var urls: [URL] = []
                for relay in feedRelays where !own.contains(relay) {
                    if let url = URL(string: relay), !urls.contains(url) { urls.append(url) }
                }
                // One relay at a time: a follow list is the whole list (~90 KB
                // for 1,000 follows), so asking every relay at once would
                // download the same lists several times. Stop as soon as
                // enough bridges are known.
                let filters = TrustPath.filters(author: author, follows: follows)
                var signers = Set<String>()
                for url in urls.prefix(Self.maxRelays) {
                    let found = await ZapHistoryService.query(filters: filters, relays: [url], timeout: 5)
                    if !found.isEmpty { anyRelayAnswered = true }
                    for list in found {
                        if let signer = list["pubkey"] as? String { signers.insert(signer) }
                        lists.append(list)
                    }
                    if signers.count >= TrustPath.listsPerFilter { break }
                }
            }
            let path = TrustPath.resolve(author: author, me: me, follows: Set(follows),
                                         trustGraph: trustGraph, contactLists: lists)
            return (path, anyRelayAnswered)
        }
        inFlight[key] = task
        let (result, anyRelayAnswered) = await task.value
        inFlight[key] = nil
        // An empty answer may just be relays timing out, and an account switch
        // mid-query computed against the old follows: retry those next time.
        if anyRelayAnswered || result.reach == .follow,
           ConfigService.shared.activeAccountHexPubkey == me {
            cache[key] = result
        }
        return result
    }
}
