import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Loads WOT pubkeys from the relay's cached `wot_cache.json` file.
    /// The relay computes this graph (owner -> follows -> follows-of-follows,
    /// filtered by minimum follower count) and persists it to disk.
    func loadWotPubkeys() {
        let cacheURL = ConfigService.shared.relayDataDir.appendingPathComponent("wot_cache.json")
        wotCacheStamp = (cacheURL.path, Self.modificationDate(of: cacheURL))
        // nil = could not read the cache; keep whatever graph we already have.
        // Empty = read fine, but the graph names nobody but the owner (a new
        // account with no follows). That is no trust data, and the Global feed
        // treats an empty set as "show everything" rather than filtering the
        // whole world out — so it must be applied, not skipped, or a previous
        // account's graph would linger after a switch.
        guard let loaded = FeedFilterEngine.loadWotPubkeys(
            from: cacheURL,
            ownerHex: ConfigService.shared.activeAccountHexPubkey
        ) else {
            #if DEBUG
            print("FeedService: Could not read WOT cache from \(cacheURL.path)")
            #endif
            return
        }
        // Vouches first: $wotPubkeys fires in willSet, and its subscribers
        // read the vouches straight away.
        wotVouches = (try? Data(contentsOf: cacheURL)).flatMap(TrustMap.vouches(fromCache:))
        wotPubkeys = loaded
        wotCacheRead = true
        #if DEBUG
        print("FeedService: Loaded \(wotPubkeys.count) usable WOT pubkeys from cache")
        #endif
        // Re-filter if we're currently in global mode
        if isGlobalLikeMode {
            recomputeFilteredNotes()
        }
    }

    /// `loadWotPubkeys()`, unless the cache file is the one already read.
    private func loadWotPubkeysIfChanged() {
        let cacheURL = ConfigService.shared.relayDataDir.appendingPathComponent("wot_cache.json")
        if let stamp = wotCacheStamp, stamp.path == cacheURL.path,
           stamp.modified == Self.modificationDate(of: cacheURL) {
            return
        }
        loadWotPubkeys()
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Who counts as inside your network in the Relay tab: the relay's trust
    /// graph plus your current follows. The graph is rebuilt about once a day,
    /// so without the follows someone you just followed stayed "outside".
    /// Empty while the graph isn't loaded, which counts nobody as outside.
    func relayTabTrustedPubkeys() -> Set<String> {
        if wotPubkeys.isEmpty { loadWotPubkeysIfChanged() }
        return feedTrustedPubkeys
    }

    /// The one rule every feed with a Global button follows (Global, Media,
    /// Articles, diVines, Recipes, Live, Marketplace): Global shows your Web of
    /// Trust until the shield is switched to Everyone. nil means everyone.
    /// Fails closed like the Global feed: with no graph yet, nobody passes.
    func globalTrustSet() -> Set<String>? {
        guard !ConfigService.shared.config.globalShowsEveryone else { return nil }
        if wotPubkeys.isEmpty { loadWotPubkeysIfChanged() }
        return feedTrustedPubkeys
    }

    /// Your web right now, the one set every Global view and the Relay tab
    /// filter against: the saved graph plus your current follows
    /// (`TrustMap.web`). The graph is rebuilt about once a day, so without the
    /// follows someone you just followed stayed filtered out of Global until
    /// then. Empty while there is no graph, so Global still fails closed.
    var feedTrustedPubkeys: Set<String> {
        TrustMap.web(saved: wotPubkeys, follows: Set(followedPubkeys))
    }

    /// REQ filters for a Global view under `trust`. Everyone: the filter as
    /// is. Web of Trust: the same filter asked twice, once restricted to
    /// trusted authors, so a page of strangers cannot crowd out the people
    /// the view will actually show, and once open, for trusted authors past
    /// the cap. The caller still drops untrusted authors from both.
    static func trustScopedFilters(_ base: [String: Any], trust: Set<String>?) -> [[String: Any]] {
        guard let trust, !trust.isEmpty else { return [base] }
        var byAuthor = base
        byAuthor["authors"] = Array(trust.sorted().prefix(trustedAuthorsCap))
        return [byAuthor, base]
    }

    /// True when the Global feed has a trust graph to filter against. The
    /// relay writes `wot_cache.json` shortly after first launch; an owner who
    /// follows nobody has no graph at all, because nothing but the owner's own
    /// follows may build one.
    var curatedGraphReady: Bool { !wotPubkeys.isEmpty }

    /// The real follow list has loaded for the active account: the same test
    /// Follow uses before it publishes. Until then `followedPubkeys` can read
    /// empty for someone who follows hundreds.
    var followListIsKnown: Bool {
        ContactManager.mayPublishFollowList(hasAttemptedLoad: hasAttemptedContactLoad,
                                            isLoading: isLoadingContacts,
                                            listConfirmed: contactListConfirmed)
    }

    /// The graph is built and names nobody: the owner follows no one yet.
    /// Feeds that fail closed say so, and the topic feed opens up (labelled)
    /// so there is somewhere to find people to follow.
    var hasNoWebOfTrustYet: Bool { wotCacheRead && wotPubkeys.isEmpty }

    /// Everyone around the user for ranking search and mention results after
    /// their follows: the relay's Web of Trust graph plus the extended network
    /// (follows of follows), whichever has loaded.
    var webOfTrustForRanking: Set<String> {
        wotPubkeys.union(extendedNetworkPubkeys)
    }

    /// Status text for a Global feed with no graph yet. Global fails closed, so
    /// without this the user would sit in front of an empty screen labelled
    /// "No notes found" and reasonably conclude the app is broken.
    var curatedGraphPendingStatus: String {
        hasNoWebOfTrustYet
            ? "Follow people to build your web of trust"
            : "Building your web of trust…"
    }

    /// Re-read the trust graph until the relay has written one, then re-filter.
    /// Only runs while it would change what is on screen: a Global feed with an
    /// empty graph shows nothing at all.
    func pollForCuratedGraph() {
        curatedGraphPollTimer?.invalidate()
        curatedGraphPollAttempts = 0
        guard needsCuratedGraph, !curatedGraphReady else { return }

        connectionStatus = curatedGraphPendingStatus
        curatedGraphPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                self.curatedGraphPollAttempts += 1
                // ~2 minutes. If the graph has not appeared by then the relay
                // could not reach its seed relays, and retrying forever just
                // burns battery behind a screen that is already honest.
                guard self.needsCuratedGraph, self.curatedGraphPollAttempts <= 40 else {
                    timer.invalidate()
                    self.curatedGraphPollTimer = nil
                    return
                }
                self.loadWotPubkeysIfChanged()
                if self.curatedGraphReady {
                    timer.invalidate()
                    self.curatedGraphPollTimer = nil
                    // Popular is computed by the relay, which withholds the
                    // feed entirely until the same graph exists — re-filtering
                    // an empty list would leave the user on "Building…"
                    // forever, so ask for it again now that it can be built.
                    if self.feedMode == .popular {
                        self.loadPopularFeed()
                        return
                    }
                    self.recomputeFilteredNotes()
                    self.connectionStatus = self.filteredNotes.isEmpty ? "No notes found" : "Live"
                }
            }
        }
    }

    /// "No notes found" is a lie while the Global feed is waiting for its
    /// trust graph — there are plenty of notes, we just will not show notes we
    /// cannot vouch for.
    func emptyFeedStatus() -> String {
        if !filteredNotes.isEmpty { return "Live" }
        if needsCuratedGraph && !curatedGraphReady { return curatedGraphPendingStatus }
        return "No notes found"
    }

    /// Feeds that cannot be rendered without the trust graph. Global filters
    /// against it here; Popular is scored against it inside the relay, which
    /// withholds the feed rather than ranking whatever the largest bot pool
    /// promoted. Both look identically broken — an empty list — without this.
    private var needsCuratedGraph: Bool {
        isGlobalLikeMode || feedMode == .popular
    }
}
