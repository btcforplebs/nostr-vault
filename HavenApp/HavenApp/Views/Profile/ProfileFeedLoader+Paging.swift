import SwiftUI
import Combine

extension ProfileFeedLoader {
    // MARK: - Follower pages

    /// Asks every relay for the next 100 lists naming this profile, older
    /// than the oldest already seen; the first page, when none has been seen.
    /// Pages have their own connections: the Followers list covers the
    /// profile on iPhone, which stops the page's own load, and a page in
    /// flight must not hold up the notes behind 7 MB of contact lists.
    func loadMoreFollowers() {
        flushPendingNotes()
        let urls = profileRelayURLs
        guard followerPageSubId == nil, !followersExhausted, !urls.isEmpty else { return }
        var filter: [String: Any] = ["kinds": [3], "#p": [pubkey], "limit": 100]
        if let oldest = followerSeenAt.values.min() { filter["until"] = Int(oldest) - 1 }
        let subId = "followers-page-\(UUID().uuidString.prefix(6))"
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let str = String(data: data, encoding: .utf8) else { return }
        followerPageToken &+= 1
        let token = followerPageToken
        followerPageSubId = subId
        followerPagePending = Set(urls.indices)
        followerPageCountBefore = followerSeenAt.count

        for (relay, url) in urls.enumerated() {
            let client = WebSocketClient()
            followerClients.append(client)
            client.messageSubject
                .receive(on: parseQueue)
                .compactMap(ProfileRelayMessage.init)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handleProfileNoteMessage(message, relay: relay)
                }
                .store(in: &followerCancellables)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    if state == .error { self?.followerPageRelayAnswered(relay) }
                    if state == .connected { client?.send(text: str) }
                }
                .store(in: &followerCancellables)
            client.connect(url: url)
        }
        // Fallback only: a fresh connection and up to 7 MB, so longer than
        // the note pages get.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finishFollowerPage(token: token) }
    }

    /// EOSE, CLOSED or a failed connection: that relay is done with the page.
    func followerPageRelayAnswered(_ relay: Int) {
        guard followerPagePending.remove(relay) != nil, followerPagePending.isEmpty else { return }
        finishFollowerPage(token: followerPageToken)
    }

    func finishFollowerPage(token: Int) {
        guard token == followerPageToken, followerPageSubId != nil else { return }
        flushPendingNotes()
        disconnectFollowerClients()
        followerPageSubId = nil
        followerPagePending.removeAll()
        if followerSeenAt.count > followerPageCountBefore {
            quietFollowerPages = 0
        } else {
            // Two empty rounds in a row, not one: a single quiet round is more
            // often a slow relay than the end of the list.
            quietFollowerPages += 1
            if quietFollowerPages >= 2 { followersExhausted = true }
        }
        followerPagesDone += 1
    }

    private func disconnectFollowerClients() {
        for client in followerClients { client.disconnect() }
        followerClients.removeAll()
        followerCancellables.removeAll()
    }

    // MARK: - Note pages

    func loadOlderProfileNotes() {
        guard !isLoadingOlderNotes, hasMoreNotes else { return }
        flushPendingNotes()
        guard let oldest = profileNotes.last else { return }
        guard !profileClients.isEmpty else { return }
        isLoadingOlderNotes = true

        olderPageToken &+= 1
        let token = olderPageToken
        let subId = "older-\(UUID().uuidString.prefix(6))"
        olderPageSubId = subId
        olderPageAnswers = 0
        olderPageExpected = profileClients.count
        olderPageCountBefore = profileNotes.count
        olderPageVisibleBefore = currentSectionNotes.count
        olderPageSection = selectedSection

        let filter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "authors": [pubkey],
            "until": Int(oldest.createdAt.timeIntervalSince1970),
            "limit": 50
        ]
        // One subscription id for the whole page, so every relay's answer counts
        // toward the same page and the CLOSE below releases all of them.
        let req: [Any] = ["REQ", subId, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isLoadingOlderNotes = false
            return
        }
        for client in profileClients {
            client.send(text: str)
        }

        // Fallback only. Normally the page finishes when every relay has answered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finishOlderPage(token: token)
        }
    }

    func finishOlderPage(token: Int) {
        guard token == olderPageToken, isLoadingOlderNotes else { return }
        flushPendingNotes()
        isLoadingOlderNotes = false
        if let subId = olderPageSubId {
            closeProfileSubscription(subId)
            olderPageSubId = nil
        }

        let grew = profileNotes.count > olderPageCountBefore
        let visibleGrew = currentSectionNotes.count > olderPageVisibleBefore

        if grew {
            quietOlderPages = 0
        } else {
            // One quiet round is a slow relay far more often than an exhausted
            // history. Only a second empty round in a row ends paging — the old
            // code latched this off after a single 5s window and never reset it,
            // so one slow relay killed paging for the life of the screen.
            quietOlderPages += 1
            if quietOlderPages >= 2 { hasMoreNotes = false }
        }

        // The scroll sentinel only fires again when the VISIBLE list grows. A page
        // that was entirely replies adds nothing to the Notes tab, so paging would
        // stop with history still left. Carry on ourselves — bounded, so one flick
        // of the scroll cannot walk the whole archive. An empty tab is left to
        // `autoPageEmptyTab` and its own cap: chaining here too re-armed that
        // cap after every run, so an empty tab paged about 70 times, not 8.
        guard hasMoreNotes,
              !visibleGrew,
              !currentSectionNotes.isEmpty,
              olderPageSection == selectedSection,
              autoPagedInARow < 8 else {
            autoPagedInARow = 0
            return
        }
        autoPagedInARow += 1
        loadOlderProfileNotes()
    }

    /// The paging subscriptions are one-shot, but nothing ever released them.
    /// Every page leaked one on every relay, and relays that cap concurrent REQs
    /// start refusing — which this screen then read as "no more notes".
    private func closeProfileSubscription(_ subId: String) {
        let msg: [Any] = ["CLOSE", subId]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        for client in profileClients {
            client.send(text: str)
        }
    }

    func loadOlderTaggedNotes() {
        guard !isLoadingOlderTaggedNotes, hasMoreTaggedNotes else { return }
        flushPendingNotes()
        guard let oldest = taggedNotes.last else { return }
        guard !profileClients.isEmpty else { return }
        isLoadingOlderTaggedNotes = true

        olderTaggedToken &+= 1
        let token = olderTaggedToken
        let subId = "older-tagged-\(UUID().uuidString.prefix(6))"
        olderTaggedSubId = subId
        olderTaggedAnswers = 0
        olderTaggedExpected = profileClients.count
        olderTaggedCountBefore = taggedNotes.count
        olderTaggedVisibleBefore = buckets.tagged.count

        let filter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "#p": [pubkey],
            "until": Int(oldest.createdAt.timeIntervalSince1970),
            "limit": 50
        ]
        let req: [Any] = ["REQ", subId, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isLoadingOlderTaggedNotes = false
            return
        }
        for client in profileClients {
            client.send(text: str)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finishOlderTaggedPage(token: token)
        }
    }

    func finishOlderTaggedPage(token: Int) {
        guard token == olderTaggedToken, isLoadingOlderTaggedNotes else { return }
        flushPendingNotes()
        isLoadingOlderTaggedNotes = false
        if let subId = olderTaggedSubId {
            closeProfileSubscription(subId)
            olderTaggedSubId = nil
        }

        let grew = taggedNotes.count > olderTaggedCountBefore
        // Tagged hides the profile owner's own notes, so a page can grow the pool
        // without adding a single visible row — same stall as the Notes tab.
        let visibleGrew = buckets.tagged.count > olderTaggedVisibleBefore

        if grew {
            quietOlderTaggedPages = 0
        } else {
            quietOlderTaggedPages += 1
            if quietOlderTaggedPages >= 2 { hasMoreTaggedNotes = false }
        }

        // An empty Tagged tab is left to `autoPageEmptyTab`, as above.
        guard hasMoreTaggedNotes,
              !visibleGrew,
              !buckets.tagged.isEmpty,
              selectedSection == .tagged,
              autoPagedTaggedInARow < 8 else {
            autoPagedTaggedInARow = 0
            return
        }
        autoPagedTaggedInARow += 1
        loadOlderTaggedNotes()
    }

    func disconnectClients() {
        for client in profileClients {
            client.disconnect()
        }
        profileClients.removeAll()
        askedRelays.removeAll()
        profileCancellables.removeAll()
    }
}
