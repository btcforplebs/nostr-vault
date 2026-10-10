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
        let feed = FeedService.shared
        return await path(for: author, from: ConfigService.shared.activeAccountHexPubkey,
                          follows: feed.followedPubkeys, trustGraph: feed.relayTabTrustedPubkeys())
    }

    /// The same answer seen from someone else: `center`'s follows stand in for
    /// yours. The map uses it when you tap a face to re-center on them. With no
    /// trust graph for them, "no bridge found" comes back as `.unknown`.
    func path(for author: String, from center: String, follows: [String],
              trustGraph: Set<String> = []) async -> TrustPath {
        let me = ConfigService.shared.activeAccountHexPubkey
        // The whole follow set and whether the graph is loaded are in the key,
        // so a follow, an unfollow, or the graph arriving gives a fresh answer.
        let key = "\(me)|\(center)|\(author)|\(Set(follows).hashValue)|\(trustGraph.isEmpty)"
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value.0 }

        let task = Task { @MainActor () -> (TrustPath, Bool) in
            var lists: [[String: Any]] = []
            var anyRelayAnswered = author == center || follows.isEmpty
            if !anyRelayAnswered {
                // One relay at a time: a follow list is the whole list (~90 KB
                // for 1,000 follows), so asking every relay at once would
                // download the same lists several times. Stop as soon as
                // enough bridges are known.
                let filters = TrustPath.filters(author: author, follows: follows)
                var signers = Set<String>()
                for url in Self.publicRelays().prefix(Self.maxRelays) {
                    let found = await ZapHistoryService.query(filters: filters, relays: [url], timeout: 5)
                    if !found.isEmpty { anyRelayAnswered = true }
                    for list in found {
                        if let signer = list["pubkey"] as? String { signers.insert(signer) }
                        lists.append(list)
                    }
                    if signers.count >= TrustPath.listsPerFilter { break }
                }
            }
            let path = TrustPath.resolve(author: author, me: center, follows: Set(follows),
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

    // MARK: - Map

    private var followLists: [String: [String]] = [:]

    /// Who `pubkey` follows, from their newest signed follow list (one list,
    /// ~90 KB at 1,000 follows). Cached for the session; nil when no relay
    /// had it.
    func followList(of pubkey: String) async -> [String]? {
        if pubkey == ConfigService.shared.activeAccountHexPubkey { return FeedService.shared.followedPubkeys }
        if let cached = followLists[pubkey] { return cached }
        let filter: [String: Any] = ["kinds": [3], "authors": [pubkey], "limit": 1]
        let found = await ZapHistoryService.query(filters: [filter], relays: Self.listRelays(for: pubkey), timeout: 5)
        guard let follows = TrustMap.follows(of: pubkey, in: found) else { return nil }
        followLists[pubkey] = follows
        return follows
    }

    /// Where one person's follow list is asked for, all at once: the first
    /// feed relays, the index relays, and the relays they publish to. The
    /// feed relays alone missed lists the profile page found: by default
    /// they are primal, nos.lol and nostr.mom, and the last two were down
    /// (2026-10-10), while purplepag.es and the person's own relays had it.
    private static func listRelays(for pubkey: String) -> [URL] {
        let outbox = NostrService.shared.outboxRelays[pubkey] ?? []
        var urls = Array(publicRelays().prefix(maxRelays))
        for relay in NostrService.profileIndexRelays + outbox.prefix(3) {
            if let url = URL(string: relay), !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// One "show everyone" batch: more lists from `follows` that tag the
    /// author, skipping signers already `seen`. Empty once relays answered
    /// with nothing new; nil when none answered at all, so a timeout isn't
    /// mistaken for "that's everyone".
    func moreBridgeLists(author: String, follows: [String], seen: Set<String>) async -> [[String: Any]]? {
        let filters = TrustMap.nextBatch(author: author, follows: follows, seen: seen)
        guard !filters.isEmpty else { return [] }
        let answered = Flag()
        for url in Self.publicRelays().prefix(Self.maxRelays) {
            let found = await ZapHistoryService.query(filters: filters, relays: [url], timeout: 6,
                                                      onAnswered: { answered.set = true })
            let fresh = found.filter { ($0["pubkey"] as? String).map { !seen.contains($0) } ?? false }
            if !fresh.isEmpty { return fresh }
        }
        return answered.set ? [] : nil
    }

    /// "Look deeper": 3-hop routes, you → a follow → someone → the author.
    /// Two requests on one relay, a few MB of follow lists, so only on tap.
    /// nil when no relay answered, so it can be tried again.
    func deeperChains(author: String, center: String, follows: [String],
                      trustGraph: Set<String>) async -> [TrustMap.Chain]? {
        let answered = Flag()
        for url in Self.publicRelays().prefix(Self.maxRelays) {
            let seeds = await ZapHistoryService.query(filters: [TrustMap.deeperSeedFilter(author: author)],
                                                      relays: [url], timeout: 8,
                                                      onAnswered: { answered.set = true })
            guard !seeds.isEmpty else { continue }
            let via = TrustMap.deeperVia(author: author, me: center, follows: Set(follows),
                                         trustGraph: trustGraph, seeds: seeds)
            let filters = TrustMap.deeperLinkFilters(follows: follows.filter { $0 != author }, via: via)
            guard !filters.isEmpty else { return [] }
            let links = await ZapHistoryService.query(filters: filters, relays: [url], timeout: 8)
            return TrustMap.chains(me: center, follows: Set(follows), via: via, links: links)
        }
        return answered.set ? [] : nil
    }

    /// Set from a relay callback on the main queue, read after the await.
    private final class Flag { var set = false }

    /// Public relays to ask, in order. Your own relays (this device, the Mac)
    /// only keep events from you and your whitelist, so they never hold a
    /// follow's list.
    private static func publicRelays() -> [URL] {
        let config = ConfigService.shared.config
        let own: Set<String> = [config.nostrURL, config.macRelayWssURL]
        let feedRelays = config.activeFeedRelays.isEmpty
            ? RelayConfiguration.fallbackBroadcastRelays : config.activeFeedRelays
        var urls: [URL] = []
        for relay in feedRelays where !own.contains(relay) {
            if let url = URL(string: relay), !urls.contains(url) { urls.append(url) }
        }
        return urls
    }
}
