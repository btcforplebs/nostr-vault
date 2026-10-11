import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// How many people the follows bring in: the people they follow, fresh
    /// (the cached tally predates the follows just made).
    func countExtendedNetwork(completion: @escaping (Int) -> Void) {
        loadExtendedNetwork(forceRefresh: true) { [weak self] in
            completion(self?.extendedNetworkPubkeys.count ?? 0)
        }
    }

    func loadExtendedNetwork(forceRefresh: Bool = false, completion: @escaping () -> Void) {
        guard !followedPubkeys.isEmpty else {
            completion()
            return
        }

        // Reuse cached result if recent enough
        let cacheAge = extendedNetworkWasPartial
            ? Self.partialExtendedNetworkCacheAge
            : Self.extendedNetworkCacheAge
        if !forceRefresh,
           !extendedNetworkPubkeys.isEmpty,
           let computedAt = extendedNetworkComputedAt,
           Date().timeIntervalSince(computedAt) < cacheAge {
            #if DEBUG
            print("FeedService: Reusing cached extended network (\(extendedNetworkPubkeys.count) pubkeys, age \(Int(Date().timeIntervalSince(computedAt)))s)")
            #endif
            completion()
            return
        }

        isLoadingExtendedNetwork = true
        connectionStatus = "Analyzing network..."

        // One completion, whichever path gets there first. The timer and the
        // fetch each used to call it unconditionally, so a fetch that landed
        // after the timeout started the feed subscription a second time.
        var didComplete = false
        let completeOnce: () -> Void = {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }

        extendedNetworkTimeout?.invalidate()
        extendedNetworkTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingExtendedNetwork else { return }
                self.isLoadingExtendedNetwork = false
                completeOnce()
            }
        }

        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        fetchExtendedNetworkInParallel(from: candidates, rootPubkeys: followedPubkeys) { [weak self] mutualCounts, everyRelayAnswered in
            guard let self = self else { return }
            self.extendedNetworkTimeout?.invalidate()
            self.extendedNetworkPubkeys = ContactManager.rankExtendedNetwork(mutualCounts: mutualCounts)
            // Only a tally every relay finished is worth keeping for an hour;
            // a partial one is used, but re-asked for in five minutes rather
            // than frozen in the cache and on disk. (The flag does not survive
            // a snapshot restore, which treats a restored network as complete.)
            self.extendedNetworkComputedAt = Date()
            self.extendedNetworkWasPartial = !everyRelayAnswered
            self.isLoadingExtendedNetwork = false
            completeOnce()
        }
    }

    /// Computes 2-hop mutual-follow counts rooted at `rootPubkeys` — fetches each
    /// root pubkey's own kind-3 follow list from `relays`, tallying how many roots
    /// follow each second-hop person (excluding the roots themselves).
    ///
    /// Each root's follow list is kept once, newest revision wins, and the tally
    /// is run at the end over that set. Counting each event as it arrived meant
    /// a root whose kind-3 sat on three relays voted three times, and a stale
    /// revision from a lagging relay voted alongside the current one — so being
    /// well replicated outranked being widely followed.
    ///
    /// `completion`'s second value is whether every relay answered every chunk;
    /// false means the result is a partial tally the caller should not cache.
    private func fetchExtendedNetworkInParallel(
        from relays: [URL],
        rootPubkeys: [String],
        completion: @escaping ([String: Int], Bool) -> Void
    ) {
        guard !relays.isEmpty, !rootPubkeys.isEmpty else {
            completion([:], false)
            return
        }

        var completed = false
        var eoseCount = 0
        var clients: [WebSocketClient] = []
        /// Newest kind-3 seen per root: created_at and its p-tags.
        var followLists: [String: (createdAt: Int64, tags: [[String]])] = [:]

        // Exclude the roots themselves
        let excludeSet = Set(rootPubkeys)

        // One REQ per chunk per relay, so a whole answer is every relay
        // EOSE-ing every chunk. Counting one EOSE per relay ended the tally
        // after the first chunk came back — with more than 200 follows that
        // threw away most of the follow lists, and kept whatever the fastest
        // relay had said.
        let chunkSize = 200
        let chunkCount = (rootPubkeys.count + chunkSize - 1) / chunkSize
        let expectedEOSE = relays.count * chunkCount

        let finish: (Bool) -> Void = { everyRelayAnswered in
            guard !completed else { return }
            completed = true
            clients.forEach { $0.disconnect() }
            var mutualCounts: [String: Int] = [:]
            for (_, list) in followLists {
                for (pk, count) in ContactManager.countMutualFollows(
                    eventTags: list.tags,
                    excludeSet: excludeSet
                ) {
                    mutualCounts[pk, default: 0] += count
                }
            }
            completion(mutualCounts, everyRelayAnswered)
        }

        for url in relays {
            let c = WebSocketClient()
            c.isTemporary = true
            clients.append(c)

            c.messageSubject
                .receive(on: DispatchQueue.global(qos: .userInitiated))
                .sink { msg in
                    guard !completed else { return }
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let eventDict = json[2] as? [String: Any],
                       let kind = eventDict["kind"] as? Int, kind == 3,
                       let author = eventDict["pubkey"] as? String,
                       let createdAt = eventDict["created_at"] as? Int64,
                       let tags = eventDict["tags"] as? [[String]] {

                        DispatchQueue.main.async {
                            guard !completed else { return }
                            // Same root from another relay, or an older
                            // revision of its list: keep one, newest wins.
                            if let existing = followLists[author], existing.createdAt >= createdAt { return }
                            followLists[author] = (createdAt, tags)
                        }

                    } else if type == "EOSE" {
                        DispatchQueue.main.async {
                            eoseCount += 1
                            if eoseCount >= expectedEOSE {
                                finish(true)
                            }
                        }
                    }
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard !completed, state == .connected else { return }

                    var current = 0
                    var chunkIndex = 0
                    while current < rootPubkeys.count {
                        let end = min(current + chunkSize, rootPubkeys.count)
                        let chunk = Array(rootPubkeys[current..<end])
                        let filter: [String: Any] = ["kinds": [3], "authors": chunk]
                        let req = ["REQ", "ext-\(chunkIndex)-\(UUID().uuidString.prefix(4))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            c.send(text: str)
                        }
                        current = end
                        chunkIndex += 1
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }

        // Without this, a single relay that never connects or never sends EOSE
        // (a slow/offline relay, or one that just doesn't implement it) stalls
        // this forever — finish() otherwise only fires once every relay has
        // answered every chunk, which a bad relay can never contribute to.
        // Reaching here means the tally is partial, so it is not cacheable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { finish(false) }
    }
}
