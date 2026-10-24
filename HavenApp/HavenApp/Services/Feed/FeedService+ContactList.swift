import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Starts loading the follow list if nothing has yet. The Popular, Live,
    /// Reels and Music feeds never load it on their own, so on a launch into
    /// one of them Follow was refused until you visited Following.
    func ensureContactListLoading() {
        guard !isLoadingContacts, !hasAttemptedContactLoad else { return }
        loadContactList {}
    }

    /// Applies queued taps only once the real list is known; after a timeout
    /// they stay queued. Taps made under another account are discarded.
    private func applyPendingFollowActions() {
        guard ContactManager.mayPublishFollowList(hasAttemptedLoad: hasAttemptedContactLoad,
                                                  isLoading: isLoadingContacts,
                                                  listConfirmed: contactListConfirmed),
              !pendingFollowActions.isEmpty else { return }
        let account = currentSnapshotKey()
        let actions = pendingFollowActions.filter { $0.account == account }
        pendingFollowActions.removeAll()
        for action in actions {
            let name = NostrService.shared.profiles[action.pubkey]?.bestName ?? "npub…" + String(action.pubkey.suffix(6))
            let failed = FollowActions.publishFailed(name, follow: action.follow)
            let result = action.follow ? followUser(action.pubkey, onPublishFailed: failed)
                                       : unfollowUser(action.pubkey, onPublishFailed: failed)
            // Turn the tap's "Following…" pill into the confirmation. A list
            // still unavailable re-queues the action and keeps the pill.
            switch result {
            case .success, .failure(.alreadyFollowing):
                FollowNotificationManager.shared.resolvePending(pubkey: action.pubkey,
                                                                kind: action.follow ? .followed : .unfollowed)
            case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                break
            case .failure:
                FollowNotificationManager.shared.resolvePending(pubkey: action.pubkey, kind: nil)
            }
        }
    }

    func queueFollowAction(_ pubkey: String, follow: Bool) {
        pendingFollowActions.removeAll { $0.pubkey == pubkey }
        pendingFollowActions.append((pubkey, follow, currentSnapshotKey()))
        if !isLoadingContacts {
            if hasAttemptedContactLoad { scheduleContactRetry() } else { ensureContactListLoading() }
        }
    }

    func loadContactList(completion: @escaping () -> Void) {
        let activeNpub = ConfigService.shared.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = activeNpub.isEmpty ? ConfigService.shared.config.ownerNpub : activeNpub
        guard !targetNpub.isEmpty,
              let ownerHex = Bech32.decode(targetNpub)?.hexString else {
            completion(); return
        }

        // Prime the local-edit guard from THIS account's durable backup before
        // fetching, so a relay copy older than our last known edit can't clobber it
        // — even on a cold start where the feed disk snapshot has expired (7-day TTL).
        // Reset across account switches so a previous account's timestamp can't
        // block the new account's relay copy.
        let snapshotKey = currentSnapshotKey()
        if ownContactListAccountKey != snapshotKey {
            ownContactListAccountKey = snapshotKey
            ownContactListCreatedAt = 0
        }
        ownContactListCreatedAt = max(
            ownContactListCreatedAt,
            FollowingBackupService.shared.latestContactListCreatedAt(forAccountKey: snapshotKey)
        )

        // Mark in-flight synchronously so a reconcile firing during the readiness
        // await doesn't kick off a duplicate fetch.
        isLoadingContacts = true
        connectionStatus = "Fetching contact list…"
        // The safety timeout starts now, not after the relay-readiness wait
        // below: otherwise the window in which Follow is refused ran to 23s.
        startContactLoadingTimeout(completion: completion)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Give the local relay a chance to come up so it can serve the
            // authoritative kind-3 contact list. Bounded; warm starts return
            // immediately, and external relays are queried regardless of the result.
            _ = await RelayProcessManager.shared.ensureRelayReady(timeout: 8.0)
            // Bail if a newer load or an account switch superseded this one.
            guard self.isLoadingContacts,
                  ownerHex == ConfigService.shared.activeAccountHexPubkey else { return }
            self.beginContactFetch(ownerHex: ownerHex, completion: completion)
        }
    }

    /// The WOT tab's refresh: fetch your follow list again now. Returns once it
    /// lands or times out; a fetch already running counts as this one.
    func refreshContactList() async {
        if isLoadingContacts {
            for _ in 0..<64 where isLoadingContacts {
                try? await Task.sleep(for: .milliseconds(250))
            }
            return
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var resumed = false
            loadContactList {
                guard !resumed else { return }
                resumed = true
                done.resume()
            }
        }
    }

    private func startContactLoadingTimeout(completion: @escaping () -> Void) {
        // Safety timeout: if contact loading hasn't finished in 15 seconds, force completion
        contactLoadingTimeout?.invalidate()
        contactLoadingTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingContacts else { return }
                #if DEBUG
                print("FeedService: Contact loading timed out after 15s — forcing completion")
                #endif
                self.isLoadingContacts = false
                self.hasAttemptedContactLoad = true
                self.connectionStatus = self.followedPubkeys.isEmpty ? "Contact fetch timed out" : "Loaded \(self.followedPubkeys.count) contacts"
                self.handleContactLoadResolved()
                completion()
            }
        }
    }

    private func beginContactFetch(ownerHex: String, completion: @escaping () -> Void) {
        // Connect to all relays in parallel — use the first one that returns a non-empty contact list.
        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        fetchContactListInParallel(from: candidates, ownerHex: ownerHex, completion: completion)
    }

    /// Called after a contact-load attempt resolves (success / empty / timeout).
    /// Seeds from the local following backup when the relay returned nothing
    /// (seed-and-stay, so the user sees their follows instead of an empty feed),
    /// then re-issues the primary REQ to already-connected relays whose author set
    /// has drifted. Fresh connects are handled by the caller's completion
    /// (e.g. refresh → subscribeToAllRelays); here we only repair live subs.
    private func handleContactLoadResolved() {
        defer { applyPendingFollowActions() }
        // Every load ends here (answered or timed out). A key setup just
        // made has no list anywhere, so "none found" is known for it.
        if followedPubkeys.isEmpty, FreshAccountKeys.isFresh(ConfigService.shared.activeAccountHexPubkey) {
            contactListConfirmed = true
        }
        if followedPubkeys.isEmpty {
            let backup = FollowingBackupService.shared
            backup.loadSnapshots(forAccountKey: currentSnapshotKey())
            if let latest = backup.snapshots.last, !latest.pubkeys.isEmpty {
                #if DEBUG
                print("FeedService: contact fetch empty — seeding \(latest.pubkeys.count) follows from backup, retry scheduled")
                #endif
                contactListPTags = latest.pTags
                followedPubkeys = latest.pubkeys
                contactListContent = latest.contactListContent
                lastFetchedContactCount = latest.pubkeys.count
                ownContactListCreatedAt = max(ownContactListCreatedAt, latest.contactListCreatedAt ?? 0)
                scheduleContactRetry()
            }
        }
        resubscribePrimaryIfNeeded()
    }

    /// Schedule a single background contact re-fetch ~5s out (e.g. after seeding
    /// from backup) so a slow/cold relay that wasn't ready yet gets another chance
    /// to deliver the authoritative kind-3. Guarded against looping.
    private func scheduleContactRetry() {
        guard !contactRetryScheduled else { return }
        contactRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.contactRetryScheduled = false
            guard !self.isLoadingContacts, !self.isPaused else { return }
            self.loadContactList { [weak self] in self?.resubscribePrimaryIfNeeded() }
        }
    }

    /// Opens a connection to every candidate relay simultaneously, collects the
    /// owner's kind-3 contact list from each, and commits the NEWEST one (by
    /// created_at) — kind-3 is a replaceable event, so the freshest version is
    /// authoritative, not whichever relay happens to answer first.
    private func fetchContactListInParallel(from relays: [URL], ownerHex: String, completion: @escaping () -> Void) {
        guard !relays.isEmpty else {
            contactLoadingTimeout?.invalidate()
            isLoadingContacts = false
            hasAttemptedContactLoad = true
            completion(); return
        }

        // Shared mutable state protected by main-thread dispatch.
        var completed = false
        var tally = ContactManager.EOSETally()
        var clients: [WebSocketClient] = []
        // kind-3 is a REPLACEABLE event: keep the NEWEST version across relays, not
        // the first to arrive. Taking first-to-arrive let a stale relay copy
        // overwrite a fresh local edit — e.g. unfollow then refresh resurrected the
        // unfollowed user, and a fast relay serving an old/smaller list shrank the
        // feed. We collect candidates and commit the one with the max created_at.
        var best: (pTags: [[String]], content: String, createdAt: Int)?
        var graceWork: DispatchWorkItem?

        let finalize: () -> Void = { [weak self] in
            guard let self = self, !completed, self.isLoadingContacts else { return }
            // Discard responses that raced past an account switch.
            guard ownerHex == ConfigService.shared.activeAccountHexPubkey else {
                clients.forEach { $0.disconnect() }
                return
            }
            completed = true
            graceWork?.cancel()
            self.contactLoadingTimeout?.invalidate()
            if ContactManager.loadConfirmsList(foundList: best != nil, relaysAsked: relays.count, relaysAnswered: tally.answered.count) {
                self.contactListConfirmed = true
            }
            clients.forEach { $0.disconnect() }

            if let best = best, Int64(best.createdAt) >= self.ownContactListCreatedAt,
               Int64(best.createdAt) != self.refusedContactListCreatedAt {
                let parsed = ContactManager.parseContactList(pTags: best.pTags)
                #if DEBUG
                print("FeedService: [contact] commit newest created_at=\(best.createdAt) parsed=\(parsed.pubkeys.count) (was followedPubkeys=\(self.followedPubkeys.count))")
                #endif
                self.contactListPTags = parsed.pTags
                self.followedPubkeys = parsed.pubkeys
                self.contactListContent = best.content
                self.lastFetchedContactCount = parsed.relayPTagCount
                self.ownContactListCreatedAt = max(self.ownContactListCreatedAt, Int64(best.createdAt))
                self.connectionStatus = parsed.relayPTagCount == 0 ? "No contacts found" : "Loaded \(parsed.relayPTagCount) contacts"
                // Re-filter already-loaded notes against the committed follow set so the
                // visible feed reflects it immediately (don't wait for new notes to stream).
                self.recomputeFilteredNotes()
                FollowingBackupService.shared.maybeCreateSnapshot(
                    pubkeys: self.followedPubkeys,
                    pTags: parsed.pTags,
                    contactListContent: best.content,
                    contactListCreatedAt: Int64(best.createdAt),
                    forAccountKey: self.currentSnapshotKey()
                )
            } else if let best = best {
                // The newest kind-3 any relay returned is OLDER than the contact list
                // we last published/committed locally — our latest edit (e.g. a fresh
                // follow) hasn't propagated to these relays yet, so committing it would
                // silently drop follows. Keep the local set authoritative and re-publish
                // so the network catches up (self-heal).
                #if DEBUG
                print("FeedService: [contact] relay kind-3 stale (relay created_at=\(best.createdAt) < local \(self.ownContactListCreatedAt)) — keeping \(self.followedPubkeys.count) local follows and re-publishing")
                #endif
                self.connectionStatus = self.followedPubkeys.isEmpty ? "No contacts found" : "Loaded \(self.followedPubkeys.count) contacts"
                self.publishContactList()
            } else {
                // No kind-3 found anywhere — leave the existing follow set intact.
                #if DEBUG
                print("FeedService: [contact] no kind-3 found — followedPubkeys unchanged=\(self.followedPubkeys.count)")
                #endif
                self.connectionStatus = self.followedPubkeys.isEmpty ? "No contacts found" : "Loaded \(self.followedPubkeys.count) contacts"
            }

            self.isLoadingContacts = false
            self.hasAttemptedContactLoad = true
            self.handleContactLoadResolved()
            completion()
        }

        for url in relays {
            let c = WebSocketClient()
            c.isTemporary = true
            clients.append(c)

            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in
                    // self is only a liveness check here — bail once the
                    // service is gone rather than keep draining the socket.
                    guard !completed, self != nil else { return }
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let subId = json[1] as? String, tally.isAnswer(from: url.absoluteString, subId: subId),
                       let eventDict = json[2] as? [String: Any],
                       let kind = eventDict["kind"] as? Int, kind == 3,
                       // A relay can send anything: only the user's own, validly
                       // signed list counts.
                       (eventDict["pubkey"] as? String) == ownerHex,
                       NostrEventVerifier.isValid(eventDict),
                       let tags = eventDict["tags"] as? [[String]] {
                        let pTags = tags.filter { $0.count >= 2 && $0[0] == "p" }
                        let createdAt = (eventDict["created_at"] as? Int) ?? 0
                        #if DEBUG
                        print("FeedService: [contact] kind-3 from \(url.absoluteString) pTags=\(pTags.count) created_at=\(createdAt)")
                        #endif
                        guard !pTags.isEmpty else { return }
                        let content = eventDict["content"] as? String ?? ""
                        // Keep the newest version seen so far.
                        if best == nil || createdAt > best!.createdAt {
                            best = (pTags, content, createdAt)
                        }
                        // On the first usable kind-3, start a short grace window so a
                        // newer version from another relay can still win, then commit.
                        if graceWork == nil && !completed {
                            let work = DispatchWorkItem { finalize() }
                            graceWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
                        }
                    } else if type == "EOSE", json.count >= 2, let subId = json[1] as? String {
                        tally.eose(from: url.absoluteString, subId: subId)
                        // Every relay has delivered its stored kind-3 (if any) before
                        // its EOSE — so once all have EOSE'd, `best` is the true newest.
                        if tally.answered.count >= relays.count && !completed {
                            finalize()
                        }
                    }
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard !completed, state == .connected else { return }
                    let filter: [String: Any] = ["kinds": [3], "authors": [ownerHex], "limit": 1]
                    let subId = "cl-\(UUID().uuidString.prefix(8))"
                    tally.sent(subId: subId, to: url.absoluteString)
                    let req = ["REQ", subId, filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        c.send(text: str)
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }
}
