import SwiftUI

extension TrustWebView {
    // MARK: - Faces

    /// Pictures for a globe of everyone someone follows: on yours, the
    /// people you interact with most; on anyone else's, a spread of their
    /// follows. Only pictures that have loaded.
    var ringFaces: [String] {
        guard let frame, let candidates = faceCandidates[frame.center] else { return [] }
        // With a filter on, only people it lights get a face.
        return TrustMap.pickFaces(candidates) { filterLit?.contains($0) != false && pictureRenders($0) }
    }

    /// Pictures on the outer shell for the picked layer (Close or Further
    /// out), most vouched first. Only pictures that have loaded.
    var layerFaces: [String] {
        guard isWOTTab, frame?.center == me else { return [] }
        // A filter's people take the outer faces first, as long as the layer lights them.
        if filterLit != nil {
            return TrustMap.pickFaces(filterCandidates, renders: pictureRenders, count: TrustMap.layerFaceCount)
        }
        guard let candidates = layerCandidates[layer] else { return [] }
        return TrustMap.pickFaces(candidates, renders: pictureRenders, count: TrustMap.layerFaceCount)
    }

    // MARK: - Filters

    private var filterMatches: [TrustMap.Filter: Set<String>] {
        let onGlobe = myFollows.union(web)
        return [
            .talk: Set(engagement.keys).intersection(onGlobe),
            .followsBack: followsBack.intersection(myFollows),
        ]
    }

    func toggle(_ filter: TrustMap.Filter) {
        if filters.contains(filter) { filters.remove(filter) } else { filters.insert(filter) }
        if filter == .followsBack, filters.contains(filter), followsBackLoaded != true { loadFollowsBack() }
        applyFilters(note: filter)
    }

    /// Re-lights the globe for the filters that are on and fetches pictures
    /// for who they leave. `note` shows the tapped filter's line.
    func applyFilters(note tapped: TrustMap.Filter? = nil) {
        let matches = filterMatches
        // Until the follower ledger is read, Follow you back doesn't dim anyone.
        var ready = filters
        if followsBackLoaded != true { ready.remove(.followsBack) }
        let lit = TrustMap.lit(by: ready, matches: matches)
        if lit != filterLit { filterLit = lit }
        if let tapped { showFilterNote(tapped, lit: lit, matches: matches) }
        guard let lit else { filterCandidates = []; return }
        let ranked = lit.subtracting(myFollows).sorted {
            let (a, b) = (engagement[$0] ?? 0, engagement[$1] ?? 0)
            if a != b { return a > b }
            let (va, vb) = (vouches?[$0] ?? 0, vouches?[$1] ?? 0)
            return va != vb ? va > vb : $0 < $1
        }
        let candidates = Array(ranked.prefix(TrustMap.layerFaceCount * 3))
        guard candidates != filterCandidates else { return }
        filterCandidates = candidates
        nostrService.fetchMissingProfiles(for: candidates)
        filterPictureLoader?.cancel()
        filterPictureLoader = loadPictures(candidates)
    }

    /// "214 talk with you" for one filter on; with more, how many match them all.
    private func showFilterNote(_ tapped: TrustMap.Filter, lit: Set<String>?, matches: [TrustMap.Filter: Set<String>]) {
        let on = filters.contains(tapped)
        let text: String
        if on, tapped == .followsBack, followsBackLoaded == false {
            text = "Your relay has no follower list yet"
        } else if on, tapped == .followsBack, followsBackLoaded == nil {
            text = "Checking who follows you back…"
        } else if filters.count <= 1, on {
            text = tapped.count(matches[tapped]?.count ?? 0)
        } else if let lit {
            let n = lit.count
            text = "\(n.formatted()) \(n == 1 ? "matches" : "match") \(filters.count == 2 ? "both" : "all \(filters.count)")"
        } else {
            text = "\(tapped.title) off"
        }
        filterNote.show(FilterNote(icon: on ? tapped.symbolName : "circle.slash", text: text))
    }

    private func loadFollowsBack() {
        let owner = me
        Task {
            let followers = await Task.detached(priority: .userInitiated) {
                FollowerSnapshot.load(owner: owner).map { Set($0.current.map(\.pubkey)) }
            }.value
            guard owner == me else { return }
            followsBack = followers ?? []
            followsBackLoaded = followers != nil
            applyFilters(note: filters.contains(.followsBack) && filterNote.note != nil ? .followsBack : nil)
        }
    }

    /// One icon per filter, a toggle each.
    func filterButton(_ filter: TrustMap.Filter) -> some View {
        IconFilterButton(icon: filter.symbolName, tooltip: filter.title,
                         isSelected: filters.contains(filter), color: .havenPurple) { toggle(filter) }
            .accessibilityLabel(Text(filter.title))
            .accessibilityValue(Text(filters.contains(filter) ? "On" : "Off"))
            .accessibilityAddTraits(filters.contains(filter) ? .isSelected : [])
    }

    /// Fetches the picked layer's faces. Run on each pick, since the
    /// picture loader stops after a while and profiles can arrive late.
    func prepareLayerFaces() {
        guard let candidates = layerCandidates[layer], !candidates.isEmpty else { return }
        nostrService.fetchMissingProfiles(for: candidates)
        layerPictureLoader?.cancel()
        layerPictureLoader = loadPictures(candidates)
    }

    private func pictureKey(_ pubkey: String) -> String? {
        nostrService.profiles[pubkey]?.pictureURL.map { pubkey + " " + $0.absoluteString }
    }

    private func pictureRenders(_ pubkey: String) -> Bool {
        pictureKey(pubkey).map(renderedPictures.contains) ?? false
    }

    func prepareFaces(_ key: String, forceProfiles: Bool = false) {
        guard key == author, let ring = frames[key]?.ring else { return }
        let candidates = TrustMap.faceCandidates(ring, engagement: key == me ? engagement : [:])
        faceCandidates[key] = candidates
        nostrService.fetchMissingProfiles(for: candidates, force: forceProfiles)
        pictureLoader?.cancel()
        pictureLoader = loadPictures(candidates)
    }

    /// Loads the candidates' pictures as their profiles arrive, and lets the
    /// globe take the ones that loaded once a second rather than one by one,
    /// so it settles a few times, not sixteen.
    private func loadPictures(_ candidates: [String]) -> Task<Void, Never> {
        Task {
            var asked: Set<String> = []
            var loaded: Set<String> = []
            for _ in 0..<20 {
                for pubkey in candidates {
                    guard let key = pictureKey(pubkey), !asked.contains(key),
                          !renderedPictures.contains(key),
                          let url = nostrService.profiles[pubkey]?.pictureURL else { continue }
                    asked.insert(key)
                    if AvatarImageCache.shared.image(for: url) != nil {
                        loaded.insert(key)
                    } else {
                        AvatarImageCache.shared.load(url: url) { image in
                            if image != nil { loaded.insert(key) }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !loaded.isEmpty {
                    renderedPictures.formUnion(loaded)
                    loaded.removeAll()
                }
            }
        }
    }

    /// Who you interact with, from your own events on the device relay and
    /// the ones aimed at you in its inbox (the seed relays when it isn't up).
    func loadEngagement(force: Bool = false) async {
        let feed = FeedService.shared
        let local = feed.localRelayURL
        let inbox = feed.localInboxURL
        let outward: [URL] = local.map { [$0] } ?? feed.externalRelayURLs
        let inward: [URL] = inbox.map { [$0] } ?? feed.externalRelayURLs
        let kinds = TrustMap.engagementKinds
        async let mine = ZapHistoryService.query(
            filters: [["authors": [me], "kinds": kinds, "limit": 1000]], relays: outward)
        async let toMe = ZapHistoryService.query(
            filters: [["#p": [me], "kinds": kinds, "limit": 1000]], relays: inward)
        let (mineEvents, toMeEvents) = await (mine, toMe)
        let me = me
        let scores = await Task.detached {
            TrustMap.engagementScores(mine: mineEvents, toMe: toMeEvents, me: me)
        }.value
        engagement = scores
        prepareFaces(me, forceProfiles: force)
    }

    func recomputeHaze() {
        let graph = FeedService.shared.relayTabTrustedPubkeys().union(arrivals)
        let counts = FeedService.shared.wotVouches
        let inner = myFollows.union([me, author])
        let follows = myFollows, me = me, wot = isWOTTab
        Task.detached(priority: .userInitiated) {
            let shell = TrustMap.haze(graph.subtracting(inner))
            let close = counts.map { v in Set(shell.filter { (v[$0] ?? 0) >= TrustMap.closeVouches }) } ?? []
            var layerFaces: [TrustMap.Layer: [String]] = [:]
            if wot {
                for layer in [TrustMap.Layer.close, .furtherOut] {
                    layerFaces[layer] = TrustMap.layerFaceCandidates(layer, me: me, follows: follows,
                                                                     web: graph, vouches: counts)
                }
            }
            await MainActor.run {
                if layerFaces != layerCandidates {
                    layerCandidates = layerFaces
                    prepareLayerFaces()
                }
                haze = shell
                closeHaze = close
                web = graph
                vouches = counts
                if !TrustMap.layers(hasVouches: counts != nil).contains(layer) { layer = .everyone }
            }
        }
    }
}
