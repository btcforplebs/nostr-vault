import Foundation
import Combine

extension DMService {
    // MARK: - NIP-17 Processing

    func handleIncomingGiftWrap(_ event: NostrEvent) {
        guard event.kind == 1059 else { return }
        guard !seenGiftWrapIds.contains(event.id) else { return }
        guard Self.isAuthentic(event) else { return }

        seenGiftWrapIds.insert(event.id)
        trimSeenGiftWrapIdsIfNeeded()
        // The relay's copy came back (a refresh): it is being tried now.
        if signerWaiting.removeValue(forKey: event.id) != nil {
            waitingForSignerCount = signerWaiting.count
        }

        pendingGiftWraps.append(event)
        startGiftWrapWorkersIfNeeded()
    }

    private func startGiftWrapWorkersIfNeeded() {
        while giftWrapWorkers < maxGiftWrapWorkers && !pendingGiftWraps.isEmpty {
            giftWrapWorkers += 1
            let generation = switchGeneration
            Task { await drainGiftWraps(generation: generation) }
        }
    }

    private func drainGiftWraps(generation: UInt64) async {
        while generation == switchGeneration, let next = popNewestGiftWrap() {
            await processGiftWrap(next, generation: generation)
        }
        giftWrapWorkers -= 1
        // Work queued for a new account while this worker was finishing.
        startGiftWrapWorkersIfNeeded()
    }

    /// Newest first, so the latest messages appear before the backlog.
    private func popNewestGiftWrap() -> NostrEvent? {
        guard let index = pendingGiftWraps.indices.max(by: {
            pendingGiftWraps[$0].created_at < pendingGiftWraps[$1].created_at
        }) else { return nil }
        return pendingGiftWraps.remove(at: index)
    }

    private func processGiftWrap(_ event: NostrEvent, generation: UInt64) async {
        // The signer is not answering: wait with the others, no request.
        guard signerGate.mayAsk(event.id) else {
            waitForSigner(event, autoRetry: true)
            return
        }
        do {
            // Verify account hasn't switched since we started processing
            guard self.switchGeneration == generation else { return }

            let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
            let recipientPrivkey: String? = isNIP46 ? nil : try getActivePrivateKey()

            let (senderPubkey, content, timestamp, rumorTags) = try await NIP17Service.unwrapGiftWrapAsync(event, recipientPrivkey: recipientPrivkey)

            // Re-check after async decryption
            guard self.switchGeneration == generation else { return }
            // Before any early return below: a probe that opened releases the rest.
            signerAnswered(event.id)

            let ownPubkey = self.loadedAccountPubkey
            let isFromMe = senderPubkey == ownPubkey

            // Determine counterparty from the rumor's p-tags (the actual conversation participants)
            let rumorPTagPubkeys = rumorTags
                .filter { $0.count >= 2 && $0[0] == "p" }
                .map { $0[1] }

            let counterpartyPubkey: String
            if isFromMe {
                // Self-copy: counterparty is the first p-tagged pubkey that isn't us
                counterpartyPubkey = rumorPTagPubkeys.first(where: { $0 != ownPubkey }) ?? rumorPTagPubkeys.first ?? senderPubkey
            } else {
                counterpartyPubkey = senderPubkey
            }

            let message = DMMessage(
                id: event.id,
                senderPubkey: senderPubkey,
                content: content,
                timestamp: timestamp,
                isFromMe: isFromMe
            )
            // Kept even from a blocked sender (hidden, not lost), but never unread.
            let unread = BlockedPeople.mayAlert(sender: senderPubkey, isFromMe: isFromMe,
                                                blocked: ConfigService.shared.activeAccountBlockedHexPubkeys)

            #if DEBUG
            print("Received DM from \(senderPubkey.prefix(8)): \(content.prefix(50))")
            #endif

            if let idx = conversations.firstIndex(where: { $0.id == counterpartyPubkey }) {
                guard !conversations[idx].messages.contains(where: { $0.id == event.id }) else { return }

                // If this is our own message returning from the relay, replace the
                // optimistic placeholder (which has a UUID id) with the real event.
                if isFromMe {
                    let recentThreshold = Date().addingTimeInterval(-30)
                    if let msgIdx = conversations[idx].messages.lastIndex(where: {
                        $0.isFromMe && $0.content == content && $0.timestamp > recentThreshold
                    }) {
                        conversations[idx].messages[msgIdx] = message
                        seenGiftWrapIds.insert(event.id)
                        saveConversations()
                        return
                    }
                }

                conversations[idx].messages.append(message)
                conversations[idx].messages.sort { $0.timestamp < $1.timestamp }
                if unread {
                    conversations[idx].unreadCount += 1
                }
            } else {
                let conversation = DMConversation(
                    id: counterpartyPubkey,
                    messages: [message],
                    unreadCount: unread ? 1 : 0
                )
                conversations.append(conversation)
            }

            sortConversations()
            dmUpdateSubject.send()
            saveConversations()
            // The signer answered: the next failure starts the backoff over.
            if signerWaiting.isEmpty { signerRetryAttempt = 0 }
        } catch let error as NIP17Service.NIP17Error {
            // The wrap opened to something that is not a chat message (or
            // cannot be opened with this key): it will not change, so do not
            // ask the signer about it again on the next launch.
            #if DEBUG
            print("Failed to unwrap gift wrap: \(error)")
            #endif
            guard self.switchGeneration == generation else { return }
            rememberUnreadableGiftWrap(event.id)
            signerAnswered(event.id)
        } catch {
            // Signer offline, timed out or refused: keep it and try again.
            #if DEBUG
            print("Failed to unwrap gift wrap: \(error)")
            #endif
            guard self.switchGeneration == generation else { return }
            let mayAnswerLater = Self.signerMayAnswerLater(error)
            if mayAnswerLater { signerGate.noAnswer() } else { signerAnswered(event.id) }
            waitForSigner(event, autoRetry: mayAnswerLater)
        }
    }

    /// The probe got an answer, so the signer is back: send every waiting
    /// wrap to it again.
    private func signerAnswered(_ id: String) {
        guard signerGate.answered(id) else { return }
        signerRetryAttempt = 0
        releaseWaitingForSigner()
    }

    /// No answer (offline, not connected, timed out) is worth asking again on
    /// a timer. A refusal or a signer error is not: asking again unasked
    /// would put the same request in front of the person every few minutes.
    /// Those wait for Retry, a refresh or the next foreground.
    static func signerMayAnswerLater(_ error: Error) -> Bool {
        switch error as? NIP46Error {
        case .timeout?, .offline?, .notConnected?: return true
        default: return false
        }
    }

    // MARK: - Messages waiting for the signer

    private func waitForSigner(_ event: NostrEvent, autoRetry: Bool) {
        // Out of the dedup set, so the relay's copy (on a refresh) or a retry
        // can bring it back in.
        seenGiftWrapIds.remove(event.id)
        signerWaiting[event.id] = event
        waitingForSignerCount = signerWaiting.count
        if autoRetry { scheduleSignerRetry() }
    }

    /// 10 s, 30 s, 1.5 min, then every 3 min, at most `maxSignerRetries`
    /// rounds (about 20 minutes). After that, Retry, a refresh or the next
    /// foreground asks again.
    static func signerRetryDelay(attempt: Int) -> TimeInterval {
        [10, 30, 90, 180][min(attempt, 3)]
    }

    private func scheduleSignerRetry() {
        guard signerRetryTask == nil, !signerWaiting.isEmpty,
              signerRetryAttempt < Self.maxSignerRetries else { return }
        let delay = Self.signerRetryDelay(attempt: signerRetryAttempt)
        signerRetryAttempt += 1
        signerRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.signerRetryTask = nil
            self.retryWaitingForSigner()
        }
    }

    /// Sends every waiting message back through the queue. A success clears
    /// it; a failure puts it back in `signerWaiting` and schedules the next try.
    func retryWaitingForSigner() {
        guard !signerWaiting.isEmpty else { return }
        // Asked for (Retry, refresh): once the automatic rounds are used up,
        // this allows one more, so a signer that comes back still gets asked.
        if signerRetryTask == nil { signerRetryAttempt = min(signerRetryAttempt, Self.maxSignerRetries - 1) }
        // Parked after a timeout: ask about the newest wrap only. Its answer
        // releases the rest; no answer parks them all for the next round.
        if signerGate.parked,
           let newest = signerWaiting.values.max(by: { $0.created_at < $1.created_at }) {
            signerGate.probe(newest.id)
            signerWaiting.removeValue(forKey: newest.id)
            waitingForSignerCount = signerWaiting.count
            handleIncomingGiftWrap(newest)
            return
        }
        releaseWaitingForSigner()
    }

    private func releaseWaitingForSigner() {
        let waiting = Array(signerWaiting.values)
        signerWaiting.removeAll()
        waitingForSignerCount = 0
        for event in waiting {
            handleIncomingGiftWrap(event)
        }
    }

    func clearSignerWaiting() {
        signerRetryTask?.cancel()
        signerRetryTask = nil
        signerRetryAttempt = 0
        signerGate.reset()
        signerWaiting.removeAll()
        waitingForSignerCount = 0
    }

    private func rememberUnreadableGiftWrap(_ id: String) {
        guard unreadableGiftWrapIds.insert(id).inserted else { return }
        if unreadableGiftWrapIds.count > maxUnreadableGiftWrapIds {
            unreadableGiftWrapIds = Set(unreadableGiftWrapIds.shuffled().prefix(maxUnreadableGiftWrapIds))
        }
        saveUnreadableGiftWrapIds()
    }
}
