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
        applyWotCache(FeedFilterEngine.readWotCache(from: cacheURL, ownerHex: ConfigService.shared.activeAccountHexPubkey),
                      path: cacheURL.path)
    }

    /// `loadWotPubkeysIfChanged()` with the file read and parsed off the main
    /// thread. Opening the WoT tab read it on the main thread and hung it for
    /// about 1.2 s (Tom's perf sweep 11-01 #2).
    func loadWotPubkeysInBackgroundIfChanged() async {
        let cacheURL = ConfigService.shared.relayDataDir.appendingPathComponent("wot_cache.json")
        let modified = Self.modificationDate(of: cacheURL)
        if let stamp = wotCacheStamp, stamp.path == cacheURL.path, stamp.modified == modified { return }
        await loadWotPubkeysInBackground()
    }

    /// `loadWotPubkeys()` with the file read and parsed off the main thread.
    func loadWotPubkeysInBackground() async {
        let cacheURL = ConfigService.shared.relayDataDir.appendingPathComponent("wot_cache.json")
        let owner = ConfigService.shared.activeAccountHexPubkey
        let modified = Self.modificationDate(of: cacheURL)
        let read = await Task.detached(priority: .userInitiated) {
            FeedFilterEngine.readWotCache(from: cacheURL, ownerHex: owner)
        }.value
        // An account switch while it was read: that account's load runs on its own.
        guard owner == ConfigService.shared.activeAccountHexPubkey else { return }
        wotCacheStamp = (cacheURL.path, modified)
        applyWotCache(read, path: cacheURL.path)
    }

    private func applyWotCache(_ read: FeedFilterEngine.WotCache?, path: String) {
        // nil = could not read the cache; keep whatever graph we already have.
        // Empty = read fine, but the graph names nobody but the owner (a new
        // account with no follows). That is no trust data, and the Global feed
        // treats an empty set as "show everything" rather than filtering the
        // whole world out — so it must be applied, not skipped, or a previous
        // account's graph would linger after a switch.
        guard let read else {
            #if DEBUG
            print("FeedService: Could not read WOT cache from \(path)")
            #endif
            return
        }
        // Vouches first: $wotPubkeys fires in willSet, and its subscribers
        // read the vouches straight away.
        wotVouches = read.vouches
        wotPubkeys = read.pubkeys
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

    /// After this account publishes a follow list, load the web the relay
    /// rebuilds from it as soon as the file is rewritten (`WotRebuildWatch`).
    /// Unfollowing everyone who brought someone in takes them out of Global
    /// then, not at the next mode switch.
    func watchForRebuiltWeb() {
        wotRebuildWatchTimer?.invalidate()
        // Discovery's follows-of-follows tally is an hour-long cache of the
        // old list; the next Discovery visit counts again.
        extendedNetworkComputedAt = nil
        let cacheURL = ConfigService.shared.relayDataDir.appendingPathComponent("wot_cache.json")
        let watch = WotRebuildWatch(startedAt: Date(), stampAtStart: Self.modificationDate(of: cacheURL))
        wotRebuildWatchTimer = Timer.scheduledTimer(withTimeInterval: WotRebuildWatch.interval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.wotRebuildWatchTimer === timer else {
                    timer.invalidate()
                    return
                }
                switch watch.step(stamp: Self.modificationDate(of: cacheURL), now: Date()) {
                case .wait:
                    return
                case .reload:
                    self.loadWotPubkeys()
                    fallthrough
                case .stop:
                    timer.invalidate()
                    self.wotRebuildWatchTimer = nil
                }
            }
        }
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
        trustedWebMemo.web(saved: wotPubkeys, follows: followedPubkeys)
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
        waitsForFirstFollow
            ? "Follow people to build your web of trust"
            : "Building your web of trust…"
    }

    /// The graph names nobody and neither do your follows. Someone who has
    /// just followed is waiting for the relay's next rebuild, not for a follow.
    var waitsForFirstFollow: Bool {
        hasNoWebOfTrustYet && followedPubkeys.isEmpty
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
                // ~5 minutes: the relay rebuilds a graph that names nobody
                // every 2 minutes, so a first follow can take two rounds to
                // land. If it has not appeared by then the relay could not
                // reach its seed relays, and retrying forever just burns
                // battery behind a screen that is already honest.
                guard self.needsCuratedGraph, self.curatedGraphPollAttempts <= 100 else {
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
                    self.resubscribeGlobalForNewGraph()
                    self.connectionStatus = self.filteredNotes.isEmpty ? "No notes found" : "Live"
                }
            }
        }
    }

    /// Ask every connected Global relay for the trusted authors now the graph
    /// has loaded: the primary REQ was built while the web was empty.
    private func resubscribeGlobalForNewGraph() {
        guard isGlobalLikeMode, let trust = globalTrustSet(), !trust.isEmpty else { return }
        for (key, client) in feedClients where !key.hasPrefix("page-") && client.connectionState == .connected {
            sendTrustedAuthorsSubscription(client: client, label: key, trust: trust)
        }
    }

    /// What a finished load reports. "Live" over an empty Global that is
    /// still waiting for its graph read as a feed that works and has nothing.
    var liveOrPendingStatus: String {
        filteredNotes.isEmpty && globalAwaitsGraph ? curatedGraphPendingStatus : "Live"
    }

    /// Global is filtering by a web of trust that has not loaded yet.
    var globalAwaitsGraph: Bool {
        isGlobalLikeMode && !curatedGraphReady && !ConfigService.shared.config.globalShowsEveryone
    }

    /// "No notes found" is a lie while the Global feed is waiting for its
    /// trust graph — there are plenty of notes, we just will not show notes we
    /// cannot vouch for.
    func emptyFeedStatus() -> String {
        if !filteredNotes.isEmpty { return "Live" }
        if needsCuratedGraph && !curatedGraphReady && !everyoneGlobal { return curatedGraphPendingStatus }
        return "No notes found"
    }

    /// Global with the shield on Everyone: no graph is needed to show it.
    private var everyoneGlobal: Bool {
        isGlobalLikeMode && ConfigService.shared.config.globalShowsEveryone
    }

    /// Feeds that cannot be rendered without the trust graph. Global filters
    /// against it here; Popular is scored against it inside the relay, which
    /// withholds the feed rather than ranking whatever the largest bot pool
    /// promoted. Both look identically broken — an empty list — without this.
    private var needsCuratedGraph: Bool {
        isGlobalLikeMode || feedMode == .popular
    }
}
