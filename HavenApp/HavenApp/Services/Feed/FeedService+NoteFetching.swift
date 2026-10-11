import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Requests a fetch for a note that is missing from the local state.
    /// Used for resolving thread parents. Retries after 30s if the previous attempt failed silently.
    /// `force` bypasses that throttle, for a user-initiated Retry tap.
    func fetchMissingNote(id: String, force: Bool = false) {
        guard findNote(id: id) == nil else { return }
        if unavailableNoteIds.contains(id) {
            guard force else { return }
            unavailableNoteIds.remove(id)
            noteFetchPasses[id] = nil
        }
        if fetchingNoteIds.contains(id) {
            // Allow retry if the previous attempt was more than 30s ago
            if !force, let ts = fetchingNoteTimestamps[id], Date().timeIntervalSince(ts) < 30 {
                return
            }
            fetchingNoteIds.remove(id)
        }
        fetchingNoteIds.insert(id)
        fetchingNoteTimestamps[id] = Date()
        // Queued ahead of the request, so it runs before any answer to it.
        forgetParentFetchClaim(id)

        if id.hasPrefix(QuoteReference.coordinatePrefix) {
            fetchMissingNoteByNaddr(coordinate: id)
        } else {
            noteFetchQueue.insert(id)
            scheduleNoteFetchFlush()
        }
    }

    /// Fetches an addressable event by its naddr coordinate ("naddr:<kind>:<pubkey>:<d-tag>").
    private func fetchMissingNoteByNaddr(coordinate: String) {
        guard let (kind, pubkey, dTag) = QuoteReference.parseCoordinate(coordinate) else { return }

        let filter: [String: Any] = ["kinds": [kind], "authors": [pubkey], "#d": [dTag], "limit": 1]
        let subId = "naddr-\(UUID().uuidString.prefix(6))"
        let req = ["REQ", subId, filter] as [Any]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req),
              let reqStr = String(data: reqData, encoding: .utf8) else { return }

        var candidates: [URL] = []
        if let local = localRelayURL { candidates.append(local) }
        candidates.append(contentsOf: externalRelayURLs)

        for url in candidates {
            if let activeClient = feedClients[url.absoluteString],
               activeClient.connectionState == .connected {
                activeClient.send(text: reqStr)
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        activeClient.send(text: closeStr)
                    }
                }
                continue
            }

            sendThroughLookupSocket(url: url, req: reqStr, subId: subId)
        }
    }

    // MARK: - Note Fetching logic

    private func scheduleNoteFetchFlush() {
        guard noteFetchTimer == nil else { return }
        noteFetchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushNoteFetchRequests()
            }
        }
    }

    private func flushNoteFetchRequests() {
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        guard !noteFetchQueue.isEmpty else { return }

        let ids = Array(noteFetchQueue)
        noteFetchQueue.removeAll()

        // Fan out to local + all external relays — first response wins, later ones
        // are dropped by handleParentNoteFetch's findNote guard. Local-only was too
        // slow because replies often reference notes from people you don't follow,
        // which are not mirrored on the local relay.
        var candidates: [URL] = []
        if let local = localRelayURL {
            candidates.append(local)
        }
        candidates.append(contentsOf: externalRelayURLs)
        // Every relay the feed is already connected to (outbox relays of the
        // people you follow included): free to ask, and it's where replies
        // you can see came from.
        candidates.append(contentsOf: feedClients
            .filter { $0.value.connectionState == .connected }
            .compactMap { URL(string: $0.key) })
        var seenRelays = Set<String>()
        candidates = candidates.filter { seenRelays.insert(Self.normalizeRelayKey($0.absoluteString) ?? $0.absoluteString).inserted }

        #if DEBUG
        print("FeedService: Fetching \(ids.count) missing notes for threading")
        #endif

        var requests: [(URL, [String])] = candidates.map { ($0, ids) }

        // Relay hints and author outboxes: each asked only for the ids that
        // need it, and capped so one flush can't open dozens of sockets.
        var extra: [String: (URL, [String])] = [:]
        var authorsWithoutRelayList = Set<String>()
        for id in ids {
            var urls: [URL] = []
            if let hint = noteRelayHints[id] { urls.append(hint) }
            if let author = noteAuthorHints[id] {
                if let outbox = NostrService.shared.outboxRelays[author] {
                    urls.append(contentsOf: outbox.prefix(3).compactMap { URL(string: $0) })
                } else {
                    authorsWithoutRelayList.insert(author)
                }
            }
            for url in urls {
                let key = Self.normalizeRelayKey(url.absoluteString) ?? url.absoluteString
                guard !seenRelays.contains(key) else { continue }
                if extra[key] == nil { extra[key] = (url, []) }
                extra[key]?.1.append(id)
            }
        }
        // Keep the relays that cover the most missing notes. The cap used to
        // apply in arrival order, so the first ids' relays filled it and
        // everything after was asked nowhere: on 2026-10-01 that skipped the
        // hint or outbox relay for 141 of the 366 roots still missing after
        // the fallbacks. The retry pass gets a bigger budget, since by then
        // the authors' relay lists have usually arrived.
        let hintCap = ids.contains { (noteFetchPasses[$0] ?? 0) >= 1 } ? 24 : 12
        if extra.count > hintCap {
            let kept = extra.sorted { $0.value.1.count > $1.value.1.count }.prefix(hintCap)
            extra = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        requests.append(contentsOf: extra.values)
        // Second pass: every fallback relay gets every id still missing. These
        // sit outside the hint cap above, so busy hint relays can't crowd
        // them out.
        let retryIds = ids.filter { (noteFetchPasses[$0] ?? 0) >= 1 }
        if !retryIds.isEmpty {
            for url in Self.fallbackNoteRelays.compactMap({ URL(string: $0) }) {
                let key = Self.normalizeRelayKey(url.absoluteString) ?? url.absoluteString
                if seenRelays.contains(key) { continue }
                if var hinted = extra[key] {
                    hinted.1 = Array(Set(hinted.1).union(retryIds))
                    requests.removeAll { (Self.normalizeRelayKey($0.0.absoluteString) ?? $0.0.absoluteString) == key }
                    requests.append(hinted)
                } else {
                    requests.append((url, retryIds))
                }
            }
        }
        // Unknown relay list: fetch it now so the retry pass can ask the
        // author's own relays.
        requestRelayLists(for: authorsWithoutRelayList)

        // Check back once the relays have had time to answer: re-ask what's
        // still missing (now including hints and fallbacks), then give up.
        // The second pass mostly opens fresh sockets to relays the feed isn't
        // connected to, so it gets longer before the give-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + (retryIds.isEmpty ? 3.5 : 6)) { [weak self] in
            self?.reviewNoteFetch(ids)
        }

        for (url, ids) in requests {
            let subId = "tfetch-\(UUID().uuidString.prefix(6))"
            let filter: [String: Any] = ["ids": ids]
            let req = ["REQ", subId, filter] as [Any]
            guard let reqData = try? JSONSerialization.data(withJSONObject: req),
                  let reqStr = String(data: reqData, encoding: .utf8) else { continue }

            // Fast path: reuse an already-connected feed client for this relay.
            // This avoids a full TCP + TLS + WebSocket handshake (typically 1-3 s)
            // and delivers the parent note in milliseconds instead.
            if let activeClient = feedClients[url.absoluteString],
               activeClient.connectionState == .connected {
                activeClient.send(text: reqStr)

                // Schedule CLOSE to release the subscription on the relay after results arrive.
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        activeClient.send(text: closeStr)
                    }
                }

                #if DEBUG
                print("FeedService: tfetch reusing active connection → \(url.host ?? url.absoluteString)")
                #endif
                continue
            }

            // No feed connection: borrow a pooled lookup socket for this relay.
            sendThroughLookupSocket(url: url, req: reqStr, subId: subId)
        }
    }

    private func sendThroughLookupSocket(url: URL, req: String, subId: String) {
        let key = Self.normalizeRelayKey(url.absoluteString) ?? url.absoluteString
        if let until = lookupCooldownUntil[key] {
            if until > Date() { return }
            lookupCooldownUntil[key] = nil
        }

        if var socket = lookupSockets[key] {
            switch socket.client.connectionState {
            case .connected:
                sendLookup(req: req, subId: subId, on: socket.client)
                scheduleLookupIdleClose(key: key)
                return
            case .connecting, .disconnected:
                // Handshake still in flight (a new client starts out
                // .disconnected until connect() publishes .connecting).
                socket.pending.append((req, subId))
                lookupSockets[key] = socket
                return
            case .error:
                closeLookupSocket(key: key)
            }
        }

        let client = WebSocketClient()
        client.isTemporary = true
        var socket = LookupSocket(client: client, pending: [(req, subId)])

        client.messageSubject
            .receive(on: processingQueue)
            .compactMap { [weak self] msg in self?.verifiedParentEvent(msg) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ev in self?.handleParentNoteFetch(ev) }
            .store(in: &socket.subscriptions)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, let client,
                      self.lookupSockets[key]?.client === client else { return }
                switch state {
                case .connected:
                    let queued = self.lookupSockets[key]?.pending ?? []
                    self.lookupSockets[key]?.pending.removeAll()
                    for item in queued { self.sendLookup(req: item.req, subId: item.subId, on: client) }
                    self.scheduleLookupIdleClose(key: key)
                case .error:
                    // Refused (429 and friends), timed out or dropped.
                    self.lookupCooldownUntil[key] = Date().addingTimeInterval(Self.lookupCooldownSeconds)
                    self.closeLookupSocket(key: key)
                case .connecting, .disconnected:
                    break
                }
            }
            .store(in: &socket.subscriptions)

        lookupSockets[key] = socket
        client.connect(url: url)
    }

    private func sendLookup(req: String, subId: String, on client: WebSocketClient) {
        client.send(text: req)
        let closeMsg = ["CLOSE", subId] as [Any]
        guard let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
              let closeStr = String(data: closeData, encoding: .utf8) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupSubscriptionSeconds) { [weak client] in
            client?.send(text: closeStr)
        }
    }

    private func scheduleLookupIdleClose(key: String) {
        lookupSockets[key]?.idleClose?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeLookupSocket(key: key) }
        lookupSockets[key]?.idleClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupIdleSeconds, execute: work)
    }

    private func closeLookupSocket(key: String) {
        guard let socket = lookupSockets.removeValue(forKey: key) else { return }
        socket.idleClose?.cancel()
        socket.client.disconnect()
        // Dropping `socket` releases its subscriptions with it. They used to
        // go into `cancellables`, which kept every finished client alive.
    }

    /// Batched NIP-65 lookup for authors with no known write relays. Goes
    /// through the profile fetch (one REQ covering kind 0 and 10002 for all of
    /// them) rather than `fetchRelayList`, which opens sockets per author.
    func requestRelayLists(for authors: Set<String>) {
        if relayListRequested.count > 5000 { relayListRequested.removeAll() }
        let needed = authors.filter {
            NostrService.shared.outboxRelays[$0] == nil && relayListRequested.insert($0).inserted
        }
        guard !needed.isEmpty else { return }
        NostrService.shared.fetchMissingProfiles(for: Array(needed), force: true)
    }

    /// Second look at a fetch pass: anything still missing gets one more pass
    /// (which adds the fallback relays), then is marked unavailable so its
    /// card stops saying "Loading".
    private func reviewNoteFetch(_ ids: [String]) {
        var retry: [String] = []
        var givenUp = Set<String>()
        for id in ids where findNote(id: id) == nil && fetchingNoteIds.contains(id) {
            let passes = (noteFetchPasses[id] ?? 0) + 1
            noteFetchPasses[id] = passes
            if passes >= 2 {
                givenUp.insert(id)
                fetchingNoteIds.remove(id)
            } else {
                retry.append(id)
            }
        }
        if !givenUp.isEmpty { unavailableNoteIds.formUnion(givenUp) }
        guard !retry.isEmpty else { return }
        noteFetchQueue.formUnion(retry)
        scheduleNoteFetchFlush()
    }

    /// Runs on processingQueue. Parses a lookup response and checks its
    /// signature there, so neither costs the main thread. Once a copy of an
    /// id verifies, later copies are dropped unchecked: every relay asked
    /// answers with the same note, and main dropped the extras anyway (the id
    /// is no longer being fetched). They are dropped, never passed on
    /// unverified, since a forged event can reuse a real id.
    nonisolated func verifiedParentEvent(_ msg: String) -> [String: Any]? {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String,
              type == "EVENT", json.count >= 3,
              let ev = json[2] as? [String: Any],
              let id = ev["id"] as? String,
              !bgAccumulator.parentFetchRecentlyVerified(id),
              NostrEventVerifier.isValid(ev) else { return nil }
        bgAccumulator.markParentFetchVerified(id)
        return ev
    }

    /// A verified copy that main then dropped must not block the next fetch
    /// of the same note: without this, its later copies were discarded as
    /// duplicates for the whole claim window.
    private func forgetParentFetchClaim(_ id: String) {
        processingQueue.async { [bgAccumulator] in bgAccumulator.forgetParentFetch(id) }
    }

    /// Fast-path handler for parent note fetches — inserts directly into notes on the main
    /// thread without going through the batch accumulator or flush timers.
    /// `ev` has already passed `verifiedParentEvent`.
    func handleParentNoteFetch(_ ev: [String: Any]) {
        guard let id        = ev["id"]        as? String,
              let pubkey    = ev["pubkey"]     as? String,
              let content   = ev["content"]    as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind      = ev["kind"]       as? Int,
              let tags      = ev["tags"]       as? [[String]]
        else { return }

        // Use findNote rather than seenIds: a note can be in seenIds but evicted from
        // notes[] by the 800-cap flush, in which case we still need it in parentNotesCache.
        guard findNote(id: id) == nil else { forgetParentFetchClaim(id); return }

        // Only what was asked for, and only if it is genuine. These come from
        // relay hints and outboxes named in other people's notes, so any of
        // them can answer with a note under any id and any author's name —
        // and this one is shown as that author's post and can be embedded in
        // your reposts.
        let dTag = tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
        let coordinate = "\(QuoteReference.coordinatePrefix)\(kind):\(pubkey):\(dTag)"
        guard fetchingNoteIds.contains(id) || unavailableNoteIds.contains(id)
                || fetchingNoteIds.contains(coordinate) || unavailableNoteIds.contains(coordinate)
        else { forgetParentFetchClaim(id); return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )

        // No spam filter here: this note was fetched because something in the
        // feed references it. Dropping it didn't hide it, it left the replying
        // card on "Loading the start of this thread…" forever.

        // Cache raw event JSON for NIP-18 repost embedding
        if kind == 1 || kind == 30023 || kind == NIP10Thread.commentKind || kind == NIP88Poll.kind {
            if let evData = try? JSONSerialization.data(withJSONObject: ev, options: []),
               let evJSON = String(data: evData, encoding: .utf8) {
                cacheRawEvent(id: id, json: evJSON)
            }
        }

        if unavailableNoteIds.contains(id) { unavailableNoteIds.remove(id) }
        noteFetchPasses[id] = nil
        fetchingNoteIds.remove(id)
        fetchingNoteTimestamps.removeValue(forKey: id)
        parentNotesCache[id] = note
        noteReferencedNoteArrived(id)
        // A reply or bare repost of a blocked author is only recognisable once
        // the post it points at has loaded, so refilter when that post is theirs.
        if ConfigService.shared.activeAccountBlockedHexPubkeys.contains(pubkey) {
            recomputeFilteredNotes()
        }
        if parentNotesCache.count > parentNotesCacheTrimAt {
            // Parent edges alone are not what the timeline asks for: a thread
            // card fetches the *root*, which for anything deeper than a direct
            // reply is no note's parent, and quotes and repost originals are
            // cached here too. Trimming on parents only evicted them the moment
            // the cache filled, and the card that had just fetched its root
            // went back to "Loading the start of this thread...".
            let referencedIds = ReferencedNoteRepair.referencedIds(in: notes)
            parentNotesCache = parentNotesCache.filter { referencedIds.contains($0.key) }
            // When most of the cache is still referenced, the trim frees almost
            // nothing, and a fixed 500 re-ran this whole-feed scan on every
            // later arrival: the main thread pegged and the phone ran hot.
            // Trim again only after another 250 arrive.
            parentNotesCacheTrimAt = max(500, parentNotesCache.count + 250)
        }
        NostrService.shared.fetchMissingProfiles(for: [pubkey])
    }
}
