import SwiftUI

extension VaultView {

    // MARK: - Networking

    enum VaultRefreshMode {
        /// Tear down all connections and re-query from scratch. Needed when the
        /// connections are genuinely dead: first load, account switch, relay
        /// restart. Blanks nothing visually (events are kept), but rebuilds
        /// every socket.
        case full
        /// Keep existing connections and top up with a `since`-bounded REQ on
        /// the live subscriptions. Used on tab entry, pull-to-refresh, and
        /// feed-injection pings so re-entering the Vault tab never drops
        /// sockets or re-downloads the whole window.
        case incremental
    }

    func refreshAll(_ mode: VaultRefreshMode = .full) {
        // Only proceed if relay is actually ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("VaultView: Skipping refresh - relay not ready")
            #endif
            return
        }

        // A full refresh must never be downgraded by a later incremental
        // request landing in the same debounce window.
        if mode == .full { pendingFullRefresh = true }

        // Debounce: cancel any pending refresh and wait 0.5s before executing.
        // Multiple rapid lifecycle events (onAppear, onChange isBooting, onChange isRunning)
        // can fire within milliseconds of each other — this coalesces them into one refresh.
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            performRefresh()
        }
    }

    func performRefresh() {
        // Ask the embedded relay to fetch newly tagged events (replies, reactions,
        // zaps, reposts, mentions, DMs) and the owner's own notes from external
        // relays into the local DBs. Injected events stream in over the local
        // /inbox subscription opened by fetchNotes below. Non-blocking; no-op-safe
        // if the relay isn't running.
        // The Mac relay, when set, is one of those external relays.
        RequestRelaySyncC()

        // Fall back to a full reset when there's nothing on screen yet or the
        // sockets aren't live — an incremental top-up has nothing to reuse then.
        let needsFull = pendingFullRefresh
            || nostrService.events.isEmpty
            || nostrService.connectionStatus != "Connected"
        pendingFullRefresh = false

        if needsFull {
            nostrService.resetConnections()
        }

        // Use the centralized nostrURL which handles local vs remote correctly
        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }

        // Also query the Mac relay for tagged notes the local relay may
        // not have (e.g. due to shorter WoT depth or notes missed while suspended).
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty {
            if let macRelay = URL(string: macURL) { urls.append(macRelay) }
            if let macInbox = URL(string: macURL + "/inbox") { urls.append(macInbox) }
        }

        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)

        // Incremental: re-issue the live REQs on the existing connections,
        // bounded to what's newer than we already have (60s overlap for
        // boundary safety). fetchNotes reuses connected clients as-is.
        let since: Int64? = needsFull
            ? nil
            : nostrService.events.map(\.created_at).max().map { $0 - 60 }

        nostrService.fetchNotes(from: urls, since: since, authors: authors)
    }

    /// Fetch notes referenced by the owner's likes that aren't already in the events array.
    func fetchMissingLikedNotes() {
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return }

        // A refresh wipes the events and the liked notes with them, but the
        // ids stayed in `requestedMissingIds`, so they were never asked for
        // again and "Given" came back empty. Zaps had the same bug (#204).
        let generation = nostrService.eventsResetGeneration
        if likedNotesFetchGeneration != generation {
            likedNotesFetchGeneration = generation
            requestedMissingIds.removeAll()
        }

        let myLikes = nostrService.events.filter { $0.kind == 7 && $0.pubkey == owner }
        var likedAuthor: [String: String] = [:]
        for like in myLikes {
            guard let target = like.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] else { continue }
            if let author = like.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] { likedAuthor[target] = author }
        }
        let likedNoteIds = Set(myLikes.compactMap { event in
            event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
        })
        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(likedNoteIds.subtracting(existingIds).subtracting(requestedMissingIds))

        guard !missingIds.isEmpty else { return }
        for id in missingIds { requestedMissingIds.insert(id) }

        // You mostly like posts from the feed, which already holds them signed
        // and whole: take those now instead of waiting on relays, which on
        // 2026-10-05 returned 7 of the last 20 liked posts from primal.
        let feedCache = FeedService.shared.rawEventCache
        for id in missingIds {
            guard let json = feedCache[id], let data = json.data(using: .utf8),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: data), event.id == id else { continue }
            nostrService.injectEvent(event)
        }

        #if DEBUG
        print("VaultView: Fetching \(missingIds.count) missing liked notes")
        #endif

        // The local relay's root only holds your own events; the notes you
        // like are mostly other people's, which the embedded relay keeps on
        // /feed. Then the feed relays, then where the authors themselves write.
        var strings = [configService.config.nostrURL, configService.config.nostrURL + "/feed"]
        strings += configService.config.readRelays
        var authorRelays: [String] = []
        for id in missingIds {
            guard let author = likedAuthor[id], let outbox = nostrService.outboxRelays[author] else { continue }
            for relay in outbox.prefix(2) where !strings.contains(relay) && !authorRelays.contains(relay) {
                authorRelays.append(relay)
            }
        }
        strings += authorRelays.prefix(6)
        let urls = strings.compactMap { URL(string: $0) }

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    /// Fetch a larger set of zap receipts from the relay when entering zaps mode.
    func fetchMoreZapReceipts() {
        fetchGivenZapsFromWallet()
        let generation = nostrService.eventsResetGeneration
        guard zapReceiptsFetchGeneration != generation else { return }
        zapReceiptsFetchGeneration = generation
        // The notes those receipts point at were wiped with them.
        requestedMissingZapNoteIds.removeAll()

        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macRelay = URL(string: macURL) {
            urls.append(macRelay)
        }

        #if DEBUG
        print("VaultView: Fetching extended zap receipts history")
        #endif
        nostrService.fetchZapReceipts(from: urls, limit: 1000)

        // Your relay only holds receipts that tag you with `p`, i.e. zaps you
        // received. The receipt for a zap you sent is published to the
        // relays of the person you zapped and tags you with `P`, so "Given"
        // stayed empty. Ask the feed relays for those.
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return }
        let externalStrs = configService.config.readRelays
        // Your published inbox too: zaps sent from here ask for receipts there.
        var seen = Set<String>()
        let externalURLs = (externalStrs + (nostrService.relayLists[owner] ?? []))
            .filter { seen.insert($0.lowercased()).inserted }
            .compactMap { URL(string: $0) }
        nostrService.fetchZapReceipts(from: externalURLs, limit: 500, tagFilter: ["#P": [owner]])
    }

    /// "Given" from the wallet: the zaps the connected NWC wallet paid, matched
    /// to their posts the same way the wallet's own history is. Read once per
    /// account and wallet; a pull-to-refresh of the Relay tab does not redo it.
    func fetchGivenZapsFromWallet() {
        let owner = nostrService.activeHexPubkey
        let nwcURI = configService.config.nwcURI
        guard !owner.isEmpty, !nwcURI.isEmpty, !walletGivenLoading else { return }
        let key = owner + "|" + nwcURI
        guard walletGivenKey != key else { return }
        walletGivenKey = key
        walletGivenLoading = true
        walletGivenNotes = []
        walletGivenAmounts = [:]
        walletGivenTimes = [:]

        Task {
            defer {
                walletGivenLoading = false
                scheduleUpdateDisplayData()
            }
            var sent: [WalletTransaction] = []
            let pageSize = 50
            for page in 0..<4 {  // the 200 most recent payments
                guard let txs = try? await NWCService.listTransactions(limit: pageSize, offset: page * pageSize) else {
                    // Unsupported or unreachable: try again on the next visit.
                    if page == 0 { walletGivenKey = nil }
                    break
                }
                sent += txs.filter { $0.direction == .outgoing && $0.state == .settled }
                if txs.count < pageSize { break }
            }
            guard walletGivenKey == key, !sent.isEmpty else { return }

            let found = await ZapHistoryService.lookup(for: sent, me: owner)
            guard walletGivenKey == key else { return }
            var notes: [NostrEvent] = []
            var amounts: [String: Int64] = [:]
            var times: [String: Int64] = [:]
            for tx in sent.sorted(by: { $0.createdAt > $1.createdAt }) {
                guard let postId = found.details[tx.id]?.postId,
                      let event = found.postEvents[postId] else { continue }
                if amounts[postId] == nil {
                    notes.append(event)
                    times[postId] = Int64(tx.createdAt.timeIntervalSince1970)
                }
                amounts[postId, default: 0] += Int64(tx.amountSats)
            }
            walletGivenNotes = notes
            walletGivenAmounts = amounts
            walletGivenTimes = times
        }
    }

    /// Fetch notes referenced by zap receipts that aren't already in the events array.
    func fetchMissingZappedNotes() {
        let zapReceipts = nostrService.events.filter { $0.kind == 9735 }
        guard !zapReceipts.isEmpty || !FeedService.shared.zappedEventIds.isEmpty else { return }

        var targetNoteIds = Set<String>()
        for receipt in zapReceipts {
            if let cached = zapReceiptCache[receipt.id] {
                if let noteId = cached.targetNoteId { targetNoteIds.insert(noteId) }
            } else if let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                targetNoteIds.insert(targetId)
            }
        }

        // Posts this app zapped from this phone, for Given.
        targetNoteIds.formUnion(FeedService.shared.zappedEventIds.keys)

        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(targetNoteIds.subtracting(existingIds).subtracting(requestedMissingZapNoteIds))

        guard !missingIds.isEmpty else { return }
        for id in missingIds { requestedMissingZapNoteIds.insert(id) }

        #if DEBUG
        print("VaultView: Fetching \(missingIds.count) missing zapped notes")
        #endif

        var urls = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        urls.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    func loadMoreItems() {
        let totalCount: Int
        switch viewMode {
        case .activity, .notes, .media, .followers: totalCount = nostrService.events.count
        case .likes: totalCount = nostrService.events.count
        case .zaps: totalCount = nostrService.events.count
        }
        if maxDisplayedItems < totalCount {
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        }
    }

    func loadMore() {
        guard !nostrService.isFetching else { return }

        // Get the oldest timestamp from events. In the Vault tab, Articles and
        // Highlights page on their own and can reach far back; their pages
        // mustn't move this cursor, or Notes would skip everything between.
        let pagedApart: Set<Int> = vaultTabHostsMedia ? [VaultNoteScope.articleKind, VaultNoteScope.highlightKind] : []
        guard let oldestTimestamp = nostrService.events.last(where: { !pagedApart.contains($0.kind) })?.created_at else { return }

        // Request events strictly older than the last one we have
        #if DEBUG
        print("VaultView: Requesting older events until: \(oldestTimestamp - 1)")
        #endif
        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
            urls.append(macInbox)
        }

        nostrService.fetchNotes(from: urls, until: oldestTimestamp - 1, authors: pagingAuthors)
    }

    /// Whose posts the relay lists page through: you and your whitelist.
    var pagingAuthors: [String] {
        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        return Array(authorsSet)
    }

    /// What decides whether Articles or Highlights still need their first page.
    var firstPageKey: String {
        "\(noteScope.rawValue).\(sparseNotesScope).\(nostrService.isFetching).\(relayManager.isRunning).\(configService.config.activeAccountNpub)"
    }

    /// Articles and Highlights open on their newest page. The relay's first
    /// load is the newest posts of every kind together, so an article older
    /// than those was in none of it, and the list said "No articles found"
    /// until you tapped Load older. Waits for that first load, so a refresh
    /// that empties the events can't drop the page.
    func loadFirstPageInScope() {
        guard sparseNotesScope, relayManager.isRunning, !relayManager.isBooting,
              !nostrService.isFetching, !noOlderPages.contains(noteScope) else { return }
        let kinds = noteScope.kinds(from: NostrService.relayTabNoteKinds, split: true)
        guard !nostrService.events.contains(where: { kinds.contains($0.kind) }) else { return }
        loadOlderInScope()
    }

    /// Articles' and Highlights' "Load older": one page of just that kind from
    /// the local relay, older than the oldest one loaded, however far back.
    func loadOlderInScope() {
        guard !isLoadingOlder, let url = URL(string: configService.config.nostrURL) else { return }
        let scope = noteScope
        let kinds = scope.kinds(from: NostrService.relayTabNoteKinds, split: true)
        let oldestLoaded = nostrService.events.last(where: { kinds.contains($0.kind) })?.created_at
        let oldest = oldestLoaded ?? Int64(Date().timeIntervalSince1970)
        isLoadingOlder = true
        nostrService.fetchOlder(kinds: Array(kinds), authors: pagingAuthors, until: oldest - 1, from: [url]) { count in
            // Events land with the next buffer flush (0.3s). Wait for it, so
            // the spinner holds until the rows show.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isLoadingOlder = false
                guard let count else { return }
                // Nothing older, or a page the event caps dropped on arrival:
                // tapping again would only ask for the same page.
                let nowOldest = nostrService.events.last(where: { kinds.contains($0.kind) })?.created_at
                if count == 0 || nowOldest == nil || nowOldest == oldestLoaded {
                    noOlderPages.insert(scope)
                }
            }
        }
    }
}
