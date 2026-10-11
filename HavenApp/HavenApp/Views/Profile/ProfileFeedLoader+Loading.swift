import SwiftUI
import Combine

extension ProfileFeedLoader {
    // MARK: - Loading

    /// Where this person's articles and diVines are likely to be: the relays
    /// the profile reads, their outbox, and diVine's own relay.
    var extrasRelays: [URL] {
        var strings: [String] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            strings.append(config.nostrURL)
        }
        strings += config.readRelays.prefix(3)
        strings += (nostrService.outboxRelays[pubkey] ?? []).prefix(3)
        strings.append(ReelsFeedService.divineRelay)
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }.compactMap { URL(string: $0) }
    }

    /// The page came on screen: header, notes and counts.
    func start() {
        nostrService.fetchMissingProfiles(for: [pubkey])
        fetchAuthorNotes()
        fetchFollowerCount()
    }

    /// The page went away. Loads in flight die with their connections;
    /// without this a return before the first EOSE skips the notes load
    /// entirely.
    func stop() {
        disconnectClients()
        isLoadingNotes = false
        openingPending.removeAll()
        isLoadingOlderNotes = false
        olderPageSubId = nil
        isLoadingOlderTaggedNotes = false
        olderTaggedSubId = nil
    }

    /// Reloads in place: everything on screen stays until something newer
    /// replaces it, so the page never blanks and refills. New posts are added
    /// at the top, counts change only when a new number arrives, and the
    /// header, Shop and the extra tabs are fetched again. Returns once every
    /// relay has answered the new load, 8s at most, and not before 0.6s, so a
    /// spinner reads as having done something.
    func refresh(shop: SellerListingsLoader, extras: ProfileExtrasLoader) async {
        let started = Date()
        nostrService.fetchMissingProfiles(for: [pubkey], force: true)
        shop.load(pubkey: pubkey, force: true)
        extras.load(pubkey: pubkey, relays: extrasRelays, force: true)

        // A page of older notes in flight dies with its connection; let the
        // next scroll to the bottom ask again.
        stop()
        fetchAuthorNotes()
        fetchFollowerCount()

        while isLoadingNotes, Date().timeIntervalSince(started) < 8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let shown = Date().timeIntervalSince(started)
        if shown < 0.6 {
            try? await Task.sleep(nanoseconds: UInt64((0.6 - shown) * 1_000_000_000))
        }
    }

    /// Asks each relay for its own follower COUNT and keeps the largest.
    /// Relays hold different subsets of contact lists, so adding their
    /// counts together would double-count; the largest single answer is
    /// the closest to the real number. Your own profile shows the ledger
    /// when it has one; the relays' numbers stand in while your relay is
    /// stopped or still opening it.
    private func fetchFollowerCount() {
        let target = pubkey
        if usesOwnLedger {
            Task { [weak self] in
                let count = await Task.detached(priority: .userInitiated) {
                    FollowerSnapshot.load(owner: target)?.current.count
                }.value
                guard let count else { return }
                self?.ownLedgerCount = count
            }
        }

        var urls: [URL] = []
        var seen = Set<String>()
        // damus and primal answer COUNT; most other popular relays reject it.
        let candidates = ["wss://relay.damus.io", "wss://relay.primal.net"]
            + config.activeFeedRelays.prefix(3)
        for str in candidates where seen.insert(str).inserted {
            if let url = URL(string: str) { urls.append(url) }
        }
        let filter: [String: Any] = ["kinds": [3], "#p": [target]]

        Task { [weak self] in
            guard let count = await NostrService.shared.fetchVertexFollowerCount(target: target) else { return }
            self?.vertexFollowerCount = count
        }
        for url in urls {
            Task { [weak self] in
                guard let count = await NostrService.shared.fetchCount(from: [url], filter: filter) else { return }
                guard let self else { return }
                self.relayFollowerCount = max(self.relayFollowerCount ?? 0, count)
            }
        }
    }

    private func fetchAuthorNotes() {
        guard !isLoadingNotes else { return }
        isLoadingNotes = true
        notesLoadStarted = true

        let existing = feedService.notes.filter { $0.pubkey == pubkey }
        for note in existing {
            if !seenNoteIds.contains(note.id) {
                seenNoteIds.insert(note.id)
                pending.notes.append(note)
            }
        }
        flushPendingNotes()

        var relayURLs: [URL] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            if let local = URL(string: config.nostrURL) {
                relayURLs.append(local)
            }
        }
        // Use up to 3 external relays to improve chances of finding the user's data.
        relayURLs.append(contentsOf: config.readRelays.prefix(3).compactMap { URL(string: $0) })

        // NIP-65 outbox model: we're fetching events FROM this user, so query their
        // write/outbox relays (where they actually publish), not their read/inbox
        // relays (where others send things TO them).
        if let userRelays = nostrService.outboxRelays[pubkey] {
            let existingStrings = Set(relayURLs.map { $0.absoluteString })
            for relayStr in userRelays.prefix(3) {
                if !existingStrings.contains(relayStr), let url = URL(string: relayStr) {
                    relayURLs.append(url)
                }
            }
        }

        let pubkey = pubkey
        let notesFilter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "authors": [pubkey],
            "limit": 50
        ]
        let profileFilter: [String: Any] = ["kinds": [0], "authors": [pubkey], "limit": 1]
        let contactFilter: [String: Any] = ["kinds": [3], "authors": [pubkey], "limit": 1]
        let taggedFilter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "#p": [pubkey],
            "limit": 50
        ]
        // Followers: a sample, for anyone else's list, and for your own when
        // your relay's ledger is not open.
        let followersFilter: [String: Any] = ["kinds": [3], "#p": [pubkey], "limit": 100]
        let filters: [Any] = [notesFilter, profileFilter, contactFilter, followersFilter, taggedFilter]

        openingPending = Set(relayURLs.indices)
        for (relay, url) in relayURLs.enumerated() {
            let client = WebSocketClient()
            profileClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handleProfileNoteMessage(message, relay: relay)
                }
                .store(in: &profileCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    // A relay that can't be reached has answered too: it
                    // will send nothing.
                    if state == .error { self?.openingRelayAnswered(relay) }
                    if state == .connected {
                        let req: [Any] = ["REQ", "profile-\(UUID().uuidString.prefix(6))"] + filters
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client?.send(text: str)
                        }
                    }
                }
                .store(in: &profileCancellables)

            client.connect(url: url)
        }

        notesLoadToken += 1
        let token = notesLoadToken
        if relayURLs.isEmpty { isLoadingNotes = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, token == self.notesLoadToken else { return }
            self.flushPendingNotes()
            self.openingPending.removeAll()
            self.isLoadingNotes = false
        }
    }

    private func openingRelayAnswered(_ relay: Int) {
        guard openingPending.remove(relay) != nil else { return }
        if openingPending.isEmpty {
            flushPendingNotes()
            isLoadingNotes = false
        }
    }

    private func handleProfileNoteMessage(_ message: String, relay: Int) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EVENT", json.count >= 3,
           let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            // Handle kind 0 (profile metadata) from the target user
            if event.kind == 0, event.pubkey == pubkey {
                guard event.created_at >= shownMetadataAt else { return }
                shownMetadataAt = event.created_at
                if let result = ProfileRepository.parseMetadataContent(
                    event.content, pubkey: pubkey,
                    existingProfile: nostrService.profiles[pubkey],
                    createdAt: event.created_at
                ), result.changed {
                    nostrService.profiles[pubkey] = result.profile
                }
                return
            }

            if event.kind == 3 {
                let pTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }
                if event.pubkey == pubkey {
                    guard event.created_at >= shownContactsAt else { return }
                    shownContactsAt = event.created_at
                    // This user's own contact list → extract following count and followsMe.
                    // followsMe is true if they follow ANY of our accounts (owner or
                    // whitelisted) so the badge is consistent across account switches.
                    var seenTags = Set<String>()
                    let list = pTags.map { $0[1] }.filter { $0 != pubkey && seenTags.insert($0).inserted }
                    followingList = list
                    followingCount = pTags.filter { $0[1] != pubkey }.count
                    let ourHexKeys: Set<String> = Set(ConfigService.shared.allAccountNpubs.compactMap { Bech32.decode($0)?.hexString })
                    if !ourHexKeys.isEmpty {
                        followsMe = pTags.contains { ourHexKeys.contains($0[1]) }
                    }
                } else {
                    // Someone else's contact list containing this pubkey → they follow this user
                    followerPubkeys.insert(event.pubkey)
                    followersCount = followerPubkeys.count
                    followerSeenAt[event.pubkey] = max(followerSeenAt[event.pubkey] ?? 0, event.created_at)
                }
                return
            }

            // Check if this is a tagged event (authored by someone else, but p-tagging the profile user)
            let isTaggedEvent = event.pubkey != pubkey &&
                [1, 6, 30023, NIP88Poll.kind].contains(event.kind) &&
                event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey })

            if isTaggedEvent {
                guard !seenTaggedIds.contains(event.id) else { return }
                seenTaggedIds.insert(event.id)

                pending.tagged.append(FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                ))
                scheduleFlush()

                // Fetch profile for the tagger
                if nostrService.profiles[event.pubkey] == nil {
                    nostrService.fetchMissingProfiles(for: [event.pubkey])
                }

                // Trigger fetch of the original note for empty-content reposts
                if event.kind == 6 && event.content.isEmpty,
                   let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    feedService.fetchMissingNote(id: refId)
                }

                return
            }

            // For notes (kind 1, 6, 30023), only show from the target user
            guard event.pubkey == pubkey else { return }

            guard !seenNoteIds.contains(event.id) else { return }
            seenNoteIds.insert(event.id)

            pending.notes.append(FeedNote(
                id: event.id,
                pubkey: event.pubkey,
                content: event.content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                tags: event.tags,
                kind: event.kind
            ))
            scheduleFlush()

            // Trigger fetch of the original note for empty-content reposts
            if event.kind == 6 && event.content.isEmpty,
               let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                feedService.fetchMissingNote(id: refId)
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" || type == "CLOSED" {
            // CLOSED counts the same as EOSE: the relay is saying it will send
            // nothing more under this subscription. A refusal (sub cap, rate limit)
            // reads identically to an exhausted history from here, and ignoring it
            // left the page hanging on a relay that was never going to answer.
            let subId = (json.count >= 2 ? json[1] as? String : nil) ?? ""
            // Page bookkeeping counts the lists, so they must be complete.
            flushPendingNotes()
            if subId.hasPrefix("followers-page-") {
                guard subId == followerPageSubId else { return }
                followerPageAnswers += 1
                if followerPageAnswers >= followerPageExpected {
                    finishFollowerPage(token: followerPageToken)
                }
            } else if subId.hasPrefix("older-tagged-") {
                guard subId == olderTaggedSubId else { return }
                olderTaggedAnswers += 1
                if olderTaggedAnswers >= olderTaggedExpected {
                    finishOlderTaggedPage(token: olderTaggedToken)
                }
            } else if subId.hasPrefix("older-") {
                guard subId == olderPageSubId else { return }
                olderPageAnswers += 1
                if olderPageAnswers >= olderPageExpected {
                    finishOlderPage(token: olderPageToken)
                }
            } else {
                // The opening subscription is deliberately left open — it is also
                // how new posts reach the profile while it is on screen.
                openingRelayAnswered(relay)
            }
        }
    }
}
