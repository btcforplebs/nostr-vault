import Foundation
import Combine
import SwiftUI

extension FeedService {
    func subscribeToAllRelays() {
        if (isFollowSetMode || (feedMode == .media && mediaFeedMode == .following)) && followedPubkeys.isEmpty {
            connectionStatus = "Follow someone on Nostr to see their posts here"
            return
        }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty {
            // Two different states wore one message. Telling someone who
            // follows 400 people to follow more people blames them for a relay
            // that returned no follow lists.
            connectionStatus = followedPubkeys.isEmpty
                ? "Follow more people to build your discovery network"
                : "No follow lists came back from your relays — pull to refresh"
            return
        }

        isLoadingFeed = true
        eoseCount = 0
        primaryEoseRelays.removeAll()
        subIdToRelayKey.removeAll()
        relayErrorCounts.removeAll()
        pageLoadTimeout?.invalidate()   // must not end this load
        connectionStatus = "Loading feed…"
        // Freeze the resume window for this round before any relay connects.
        subscriptionRoundSince = lastEventTimestamp

        // Use faster flush interval during initial load for snappier content display.
        // Global mode gets ultra-fast real-time flushing for streaming effect.
        let isGlobal = isGlobalLikeMode
        processingQueue.async { [weak self] in
            self?.bgAccumulator.isInitialLoad = true
            self?.bgAccumulator.isGlobalMode = isGlobal
        }

        refreshOutboxPlan()
        let allURLs = feedRelayURLs()

        let allKeys = Set(allURLs.map { $0.absoluteString })

        // Disconnect clients for relays no longer in the active set (e.g.
        // relay list changed).  Existing connected clients are kept alive —
        // callers that need a full teardown (account switch, mode switch,
        // forceReload) already call disconnectFeedClients() before this.
        for key in feedClients.keys where !allKeys.contains(key) {
            feedClients[key]?.disconnect()
            feedClients.removeValue(forKey: key)
            if !key.hasPrefix("page-") {
                relayStateSinks.removeValue(forKey: key)
                relayStates.removeValue(forKey: Self.relayStateKey(key))
            }
        }

        let totalRelays = allURLs.count

        // Safety timeout: if feed loading hasn't finished in 20 seconds, flush what we have
        feedLoadingTimeout?.invalidate()
        feedLoadingTimeout = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingFeed else { return }
                #if DEBUG
                print("FeedService: Feed loading timed out after 20s — flushing \(self.noteBuffer.count) buffered notes (eoseCount=\(self.eoseCount)/\(totalRelays))")
                #endif
                self.flushNoteBuffer()
                self.isLoadingFeed = false
                self.isSyncing = false
                self.connectionStatus = self.emptyFeedStatus()
                self.processingQueue.async { [weak self] in
                    self?.bgAccumulator.isInitialLoad = false
                }
            }
        }

        // Connect local relay(s) immediately; stagger external connections
        // by 200ms each to avoid a TCP/TLS handshake storm on cellular.
        var externalQueue: [URL] = []
        for url in allURLs {
            let key = url.absoluteString
            if let existing = feedClients[key],
               existing.connectionState == .connected {
                // A warm account switch's cancellables.removeAll() can have orphaned
                // this client's sink (see subscribedClientKeys) without disconnecting
                // it — re-establish it before resending the REQ, or the response is
                // delivered to zero subscribers and silently dropped.
                if !subscribedClientKeys.contains(key) {
                    let isLocalRelay = url.host == "127.0.0.1" || url.host == "localhost"
                    subscribedClientKeys.insert(key)
                    existing.messageSubject
                        .receive(on: processingQueue)
                        .sink { [weak self] msg in
                            self?.handleFeedRelayMessage(msg, totalRelays: totalRelays, inject: !isLocalRelay)
                        }
                        .store(in: &cancellables)
                }
                sendPrimaryFeedSubscription(client: existing, label: key)
            } else if url == localRelayURL || url == localInboxURL || url == localFeedURL {
                connectFeedRelay(url: url, totalRelays: totalRelays)
            } else {
                externalQueue.append(url)
            }
        }
        for (index, url) in externalQueue.enumerated() {
            let key = url.absoluteString
            if feedClients[key]?.connectionState == .connected || feedClients[key]?.connectionState == .connecting {
                continue
            }
            let delay = Double(index) * 0.2
            if delay == 0 {
                connectFeedRelay(url: url, totalRelays: totalRelays)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.isPaused else { return }
                    self.connectFeedRelay(url: url, totalRelays: totalRelays)
                }
            }
        }
    }

    func connectFeedRelay(url: URL, totalRelays: Int) {
        let key = url.absoluteString
        if let existing = feedClients[key],
           existing.connectionState == .connected || existing.connectionState == .connecting {
            return
        }

        let c = WebSocketClient()
        feedClients[key] = c
        watchRelayState(c, key: key)

        let isLocalRelay = url.host == "127.0.0.1" || url.host == "localhost"

        subscribedClientKeys.insert(key)
        c.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] msg in
                self?.handleFeedRelayMessage(msg, totalRelays: totalRelays, inject: !isLocalRelay)
            }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    self.forgetDeleteRequestsSubscription(client: c)
                    self.relayErrorCounts[key] = 0
                    self.downRelayKeys.remove(key)
                    self.sendPrimaryFeedSubscription(client: c, label: key)
                case .error:
                    let errorCount = (self.relayErrorCounts[key] ?? 0) + 1
                    self.relayErrorCounts[key] = errorCount

                    if errorCount >= 3 {
                        // The follows this relay was reaching get asked
                        // somewhere else.
                        if self.downRelayKeys.insert(key).inserted {
                            DispatchQueue.main.async { [weak self] in self?.reconcileFeedSubscriptions() }
                        }
                        // After 3 failures, count this relay as done so loading can finish
                        #if DEBUG
                        print("FeedService: Relay \(key) failed \(errorCount) times — counting as EOSE")
                        #endif
                        self.eoseCount += 1
                        if self.eoseCount >= totalRelays {
                            self.feedLoadingTimeout?.invalidate()
                            self.flushNoteBuffer()
                            self.isLoadingFeed = false
                            self.isSyncing = false
                            self.connectionStatus = self.emptyFeedStatus()
                            self.processingQueue.async { [weak self] in
                                self?.bgAccumulator.isInitialLoad = false
                            }
                        }
                    } else {
                        // Retry after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard self?.feedClients[key] === c else { return }
                            self?.connectFeedRelay(url: url, totalRelays: totalRelays)
                        }
                    }
                default: break
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
    }

    /// One-shot pagination client — opens, fetches until the given timestamp, then disconnects.
    func connectFeedRelayWithUntil(url: URL, until: Int64, totalRelays: Int) {
        let key = "page-\(url.absoluteString)"
        let c = WebSocketClient()
        c.isTemporary = true
        // The previous page's client is done: loadMore waits for its EOSEs or
        // the page timeout. Overwritten without a disconnect, its socket stayed
        // open, kept alive by its sinks: one more socket per relay for every
        // page scrolled (Mac sweep 2026-11-01 #7).
        feedClients[key]?.disconnect()
        feedClients[key] = c

        let isLocalRelay = url.host == "127.0.0.1" || url.host == "localhost"

        c.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] msg in
                self?.handleFeedRelayMessage(msg, totalRelays: totalRelays, inject: !isLocalRelay)
            }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    self?.sendFeedSubscription(client: c, label: key, until: until)
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
    }

    /// Shared "since" and filter computation for feed subscriptions.
    ///
    /// Uses `subscriptionRoundSince` — the value of `lastEventTimestamp` frozen
    /// at the start of the current subscription round — NOT the live value.
    /// Relays connect at different speeds (the local /feed cache answers in
    /// milliseconds, externals stagger in over seconds); with the live value, a
    /// fast relay's notes advance the timestamp before slow relays compute
    /// their REQ, so externals get asked only for the last ~60s and everything
    /// the fast relay didn't have silently disappears from the feed.
    private func feedSinceAndLimit(until: Int64? = nil) -> (since: Int64, limit: Int) {
        let isResume = subscriptionRoundSince > 0 && until == nil
        if isResume {
            return (subscriptionRoundSince - 60, feedMode == .media ? 500 : 500)
        } else if until != nil {
            // A page older than `until`: no lower bound, so each relay returns
            // its newest notes before it however far back they are. Measured
            // from now, as it was, every page past the first week asked for an
            // empty window and scrolling back stopped there.
            return (0, feedMode == .media ? 300 : 500)
        } else if feedMode == .polls {
            // Polls are rare next to notes: a week of them from the people
            // you follow is often none, so the first page is the newest
            // polls however old.
            return (0, 500)
        } else {
            return (Int64(Date().timeIntervalSince1970) - (7 * 24 * 3600), feedMode == .media ? 300 : 500)
        }
    }

    private func feedSubId(for label: String) -> String {
        "feed-\(label.suffix(8).filter { $0.isLetter || $0.isNumber })"
    }

    /// Send only the primary feed filter (kinds 1, 6, 30023). Auxiliary subscriptions
    /// (mentions, reactions, zaps) are deferred until this relay's primary EOSE.
    func sendPrimaryFeedSubscription(client: WebSocketClient, label: String) {
        let (since, limitVal) = feedSinceAndLimit()
        let isInbox = label == localInboxURL?.absoluteString
        let isFollowingLike = isFollowSetMode || (feedMode == .media && mediaFeedMode == .following)

        // GUARD: never send a dead `authors:[]` REQ for an author-filtered mode with
        // no authors yet — it matches zero notes and would silently stick. Record
        // that no live primary sub exists so `resubscribePrimaryIfNeeded()` re-sends
        // the moment the follow set / extended network arrives.
        if !isInbox && isFollowingLike && followedPubkeys.isEmpty {
            subscribedAuthorsByRelay[label] = nil
            return
        }
        if !isInbox && feedMode == .discovery && extendedNetworkPubkeys.isEmpty {
            subscribedAuthorsByRelay[label] = nil
            return
        }

        var filter: [String: Any] = [
            "kinds": primaryFeedKinds,
            "since": since,
            "limit": limitVal
        ]

        if isInbox {
            // The inbox stores events that TAG the owner (replies, mentions) — query
            // by #p rather than authors, since the authors are external users.
            let ownerHex = NostrService.shared.activeHexPubkey
            if !ownerHex.isEmpty {
                filter["#p"] = [ownerHex]
            }
        } else if isFollowingLike {
            filter["authors"] = followAuthors(forRelayKey: label)
        } else if feedMode == .discovery {
            filter["authors"] = extendedNetworkPubkeys
        }

        let subId = feedSubId(for: label)
        subIdToRelayKey[subId] = label

        // Global under Web of Trust asks twice, once for trusted authors and
        // once open. Asked open only, a new account's small web matched almost
        // nothing in a page of strangers and Global rendered blank.
        var req: [Any] = ["REQ", subId]
        if isGlobalLikeMode && !isInbox {
            req.append(contentsOf: Self.trustScopedFilters(filter, trust: globalTrustSet()) as [Any])
        } else {
            req.append(filter)
        }
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
            // Record the author set we just subscribed with so reconcile can detect
            // drift. Inbox/global/popular carry no author filter → record [].
            if isInbox {
                subscribedAuthorsByRelay[label] = []
            } else if isFollowingLike {
                subscribedAuthorsByRelay[label] = followAuthors(forRelayKey: label)
            } else if feedMode == .discovery {
                subscribedAuthorsByRelay[label] = extendedNetworkPubkeys
            } else {
                subscribedAuthorsByRelay[label] = []
            }
        }
    }

    /// The trusted-author half of a Global REQ on its own subscription, for a
    /// graph that loaded after the primary REQ went out. Its own subId keeps
    /// its EOSE out of the primary count, which would end a running load early.
    func sendTrustedAuthorsSubscription(client: WebSocketClient, label: String, trust: Set<String>) {
        guard label != localInboxURL?.absoluteString else { return }
        let (since, limitVal) = feedSinceAndLimit()
        let filter: [String: Any] = [
            "kinds": primaryFeedKinds,
            "since": since,
            "limit": limitVal,
            "authors": Array(trust.sorted().prefix(Self.trustedAuthorsCap))
        ]
        let req: [Any] = ["REQ", "wot-" + feedSubId(for: label), filter]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    /// Send auxiliary subscriptions (mentions, reactions, zaps) to a relay after
    /// its primary feed EOSE has arrived so feed content isn't bandwidth-starved.
    func sendAuxiliarySubscriptions(client: WebSocketClient, label: String) {
        let isGlobal = isGlobalLikeMode
        guard !isGlobal else { return }

        let ownerHex = NostrService.shared.activeHexPubkey
        guard !ownerHex.isEmpty else { return }

        let (since, _) = feedSinceAndLimit()
        let subId = feedSubId(for: label)

        // Mentions (#p) of the owner (from anyone). The Polls feed asks for
        // polls only, or every mention would count in its "N new" pill.
        let mentionsFilter: [String: Any] = [
            "kinds": feedMode == .polls ? [NIP88Poll.kind] : [1, 6, 30023, NIP10Thread.commentKind, NIP88Poll.kind],
            "since": since,
            "#p": [ownerHex],
            "limit": 50
        ]
        let mReq = ["REQ", "m-\(subId)", mentionsFilter] as [Any]
        if let mData = try? JSONSerialization.data(withJSONObject: mReq),
           let mStr = String(data: mData, encoding: .utf8) {
            client.send(text: mStr)
        }

        // Reactions from followed users
        let reactionsFilter: [String: Any] = [
            "kinds": [7],
            // Plus the account's own reactions, which are what mark a note
            // as liked by you; the saved set is only a cache of them.
            "authors": followedPubkeys + [NostrService.shared.activeHexPubkey].filter { !$0.isEmpty && !followedPubkeys.contains($0) },
            "since": since,
            "limit": 150
        ]
        let rxReq = ["REQ", "rx-\(subId)", reactionsFilter] as [Any]
        if let rxData = try? JSONSerialization.data(withJSONObject: rxReq),
           let rxStr = String(data: rxData, encoding: .utf8) {
            client.send(text: rxStr)
        }

        // Incoming zap receipts (kind 9735, #p = owner)
        let incomingZapsFilter: [String: Any] = [
            "kinds": [9735],
            "#p": [ownerHex],
            "since": since,
            "limit": 50
        ]
        let inZapsReq = ["REQ", "zaps-in-\(subId)", incomingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: inZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        // Outgoing zap requests (kind 9734, authored by owner)
        let outgoingZapsFilter: [String: Any] = [
            "kinds": [9734],
            "authors": [ownerHex],
            "since": since,
            "limit": 50
        ]
        let outZapsReq = ["REQ", "zaps-out-\(subId)", outgoingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: outZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        // Your own deletion requests (kind 5), so a post deleted on another
        // device leaves this one too.
        sendDeleteRequestsSubscription(client: client, subId: subId, owner: ownerHex)
    }

    /// Combined subscription — sends primary + auxiliary at once. Used for
    /// pagination (connectFeedRelayWithUntil) where deferral isn't needed.
    private func sendFeedSubscription(client: WebSocketClient, label: String, until: Int64) {
        let (since, limitVal) = feedSinceAndLimit(until: until)
        var filter: [String: Any] = [
            "kinds": primaryFeedKinds,
            "since": since,
            "limit": limitVal
        ]
        if isFollowSetMode || (feedMode == .media && mediaFeedMode == .following) {
            filter["authors"] = followAuthors(forRelayKey: label)
        } else if feedMode == .discovery {
            filter["authors"] = extendedNetworkPubkeys
        }
        filter["until"] = until
        let subId = feedSubId(for: label)

        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        let isGlobal = isGlobalLikeMode
        guard !isGlobal else { return }

        let ownerHex = NostrService.shared.activeHexPubkey
        guard !ownerHex.isEmpty else { return }

        var mentionsFilter = filter
        mentionsFilter["#p"] = [ownerHex]
        mentionsFilter["authors"] = nil
        mentionsFilter["limit"] = 50
        let mReq = ["REQ", "m-\(subId)", mentionsFilter] as [Any]
        if let mData = try? JSONSerialization.data(withJSONObject: mReq),
           let mStr = String(data: mData, encoding: .utf8) {
            client.send(text: mStr)
        }

        let reactionsFilter: [String: Any] = [
            "kinds": [7],
            // Plus the account's own reactions, which are what mark a note
            // as liked by you; the saved set is only a cache of them.
            "authors": followedPubkeys + [NostrService.shared.activeHexPubkey].filter { !$0.isEmpty && !followedPubkeys.contains($0) },
            "since": since,
            "limit": 150,
            "until": until
        ]
        let rxReq = ["REQ", "rx-\(subId)", reactionsFilter] as [Any]
        if let rxData = try? JSONSerialization.data(withJSONObject: rxReq),
           let rxStr = String(data: rxData, encoding: .utf8) {
            client.send(text: rxStr)
        }

        let incomingZapsFilter: [String: Any] = [
            "kinds": [9735],
            "#p": [ownerHex],
            "since": since,
            "limit": 50,
            "until": until
        ]
        let inZapsReq = ["REQ", "zaps-in-\(subId)", incomingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: inZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        let outgoingZapsFilter: [String: Any] = [
            "kinds": [9734],
            "authors": [ownerHex],
            "since": since,
            "limit": 50,
            "until": until
        ]
        let outZapsReq = ["REQ", "zaps-out-\(subId)", outgoingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: outZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }
}
