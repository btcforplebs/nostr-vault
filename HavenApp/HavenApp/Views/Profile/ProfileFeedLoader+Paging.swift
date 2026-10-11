import SwiftUI
import Combine

extension ProfileFeedLoader {
    // MARK: - Follower pages

    /// Asks every relay for the next 100 lists naming this profile, older
    /// than the oldest already seen.
    func loadMoreFollowers() {
        guard followerPageSubId == nil, !followersExhausted, !profileClients.isEmpty,
              let oldest = followerSeenAt.values.min() else { return }
        followerPageToken &+= 1
        let token = followerPageToken
        let subId = "followers-page-\(UUID().uuidString.prefix(6))"
        followerPageSubId = subId
        followerPageAnswers = 0
        followerPageExpected = profileClients.count
        followerPageCountBefore = followerSeenAt.count
        let filter: [String: Any] = ["kinds": [3], "#p": [pubkey], "until": Int(oldest) - 1, "limit": 100]
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let str = String(data: data, encoding: .utf8) else {
            followerPageSubId = nil
            return
        }
        for client in profileClients { client.send(text: str) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finishFollowerPage(token: token) }
    }

    func finishFollowerPage(token: Int) {
        guard token == followerPageToken, let subId = followerPageSubId else { return }
        closeProfileSubscription(subId)
        followerPageSubId = nil
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
        // of the scroll cannot walk the whole archive.
        guard hasMoreNotes,
              !visibleGrew,
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

        guard hasMoreTaggedNotes,
              !visibleGrew,
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
        profileCancellables.removeAll()
    }
}
