import Foundation
import Combine
import SwiftUI

extension FeedService {
    // MARK: - Local DVM feeds (Popular, Catch Up, Underrated)

    /// "No popular notes found" is wrong while the trust graph is still being
    /// built: the relay is withholding the feed on purpose, and there is
    /// something to wait for. Catch Up reads only your follows.
    private func dvmEmptyStatus(_ feed: LocalDvmFeed) -> String {
        feed.needsTrustGraph && !curatedGraphReady ? curatedGraphPendingStatus : feed.emptyStatus
    }

    /// Asks the relay's local DVM for the feed on screen (Popular, Catch Up
    /// or Underrated; haven-go dvm.go, feed_catchup.go, feed_underrated.go).
    /// A result already on screen (the tab cache, or the last one saved to
    /// disk) stays up while the new one is worked out, and is swapped for it
    /// when it lands; only an empty screen shows the loading rows. Leaving
    /// the feed mid-compute no longer strands it: its flag is cleared
    /// whatever mode is showing, and the result is filed in that feed's
    /// cache for the next visit.
    func loadLocalDvmFeed() {
        let mode = feedMode
        guard let feed = mode.localDvm, !loadingDvmFeeds.contains(mode) else { return }
        guard let compute = dvmCompute(for: feed) else { return }
        loadingDvmFeeds.insert(mode)
        // The account it is computed for: an account switch mid-compute
        // drops the answer (and handleAccountSwitch already cleared the flag).
        let account = ConfigService.shared.activeAccountHexPubkey
        let showingOld = !notes.isEmpty
        if !showingOld {
            isLoadingFeed = true
            shouldScrollToTopOnLoad = true
            connectionStatus = feed.loadingStatus
            notes.removeAll()
            popularNoteScores.removeAll()
            resetFeedThreadReplies()
            recomputeFilteredNotes()
        }

        /// Ends a compute that produced nothing to show. Only this feed's own
        /// loading state and status are touched: another feed may be on screen.
        func finishEmpty(_ status: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self, ConfigService.shared.activeAccountHexPubkey == account else { return }
                self.loadingDvmFeeds.remove(mode)
                guard self.feedMode == mode else { return }
                self.isLoadingFeed = false
                // A result already on screen stays, with its status.
                if self.notes.isEmpty { self.connectionStatus = status }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let resultPtr = compute() else {
                finishEmpty(feed.emptyStatus)
                return
            }
            let jsonString = String(cString: resultPtr)
            free(resultPtr)

            // Check for error response
            if let errorData = jsonString.data(using: .utf8),
               let errorObj = try? JSONSerialization.jsonObject(with: errorData) as? [String: String],
               let errorMsg = errorObj["error"] {
                finishEmpty("Error: \(errorMsg)")
                return
            }

            // Parse the notes
            guard let data = jsonString.data(using: .utf8),
                  let dvmNotes = try? JSONDecoder().decode([PopularNoteResult].self, from: data) else {
                finishEmpty("Failed to parse results")
                return
            }

            // Convert to FeedNote and build score map
            var feedNotes: [FeedNote] = []
            var scores: [String: Double] = [:]
            for pn in dvmNotes {
                let note = FeedNote(
                    id: pn.id,
                    pubkey: pn.pubkey,
                    content: pn.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(pn.created_at)),
                    tags: pn.tags,
                    kind: pn.kind,
                    repostedBy: nil
                )
                feedNotes.append(note)
                scores[pn.id] = pn.score
            }

            DispatchQueue.main.async {
                guard let self, ConfigService.shared.activeAccountHexPubkey == account else { return }
                // Cleared before the mode check: left set, the next visit's
                // load returned at its guard and the screen sat on the
                // loading view for good.
                self.loadingDvmFeeds.remove(mode)
                guard self.feedMode == mode else {
                    // Computed for nobody on screen: kept for the next visit.
                    self.storeDvmResult(feedNotes, scores: scores, mode: mode)
                    return
                }
                // An empty answer doesn't wipe a result already showing.
                if FeedSpeedPolicy.popularReplacesShown(resultCount: feedNotes.count, showingOld: showingOld) {
                    self.notes = feedNotes
                    self.popularNoteScores = scores
                    if showingOld { self.resetFeedThreadReplies() }
                }
                self.isLoadingFeed = false
                self.connectionStatus = self.notes.isEmpty ? self.dvmEmptyStatus(feed) : "Live"
                if self.notes.isEmpty && feed.needsTrustGraph && !self.curatedGraphReady {
                    self.pollForCuratedGraph()
                }
                self.recomputeFilteredNotes()
                if !feedNotes.isEmpty { self.captureModeCache(for: mode) }
            }
        }
    }

    func resetFeedThreadReplies() {
        threadRepliesGeneration += 1
        threadRepliesRequested.removeAll()
        if !feedThreadReplies.isEmpty { feedThreadReplies = [] }
    }

    /// Fetches replies to these Popular or Global posts (once per post per
    /// list) from the local relay and the feed relays. Only signature-checked
    /// events are kept, and only real replies into one of these threads: a
    /// note that merely tags a post would open a stray thread of its own.
    /// Replies pass the same trust rule as Global's posts (`TrustGate`), in
    /// Popular too, or a post would carry the open firehose in underneath
    /// it. The post's own author and you always show.
    func loadFeedThreadReplies(rootIds: [String]) {
        guard feedMode.isLocalDvm || feedMode == .global else { return }
        let trusted = globalTrustSet()
        let wanted = rootIds.filter { !threadRepliesRequested.contains($0) }
        guard !wanted.isEmpty else { return }
        let always = Set(wanted.compactMap { findNote(id: $0)?.pubkey } + [ConfigService.shared.activeAccountHexPubkey])
        threadRepliesRequested.formUnion(wanted)
        let generation = threadRepliesGeneration
        let config = ConfigService.shared.config
        let feedRelays = config.readRelays
        let relays = ([config.nostrURL] + feedRelays).compactMap { URL(string: $0) }
        let roots = Set(wanted)
        Task { @MainActor [weak self] in
            // Relays cap filter size; ask in chunks.
            for chunk in stride(from: 0, to: wanted.count, by: 50).map({ Array(wanted[$0..<min($0 + 50, wanted.count)]) }) {
                let events = await ZapHistoryService.query(
                    filters: [["kinds": [1], "#e": chunk, "limit": 500]], relays: relays, timeout: 6)
                guard let self, self.threadRepliesGeneration == generation else { return }
                let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
                var seen = Set(self.feedThreadReplies.map(\.id))
                let replies: [FeedNote] = events.compactMap { ev in
                    guard let id = ev["id"] as? String, let pubkey = ev["pubkey"] as? String,
                          let content = ev["content"] as? String, let createdAt = ev["created_at"] as? Int64,
                          let kind = ev["kind"] as? Int, let tags = ev["tags"] as? [[String]],
                          !blocked.contains(pubkey), TrustGate.allows(pubkey, trusted: trusted, always: always),
                          !FeedNote.isNoiseOrSpam(content: content, tags: tags)
                    else { return nil }
                    let inThread = NIP10Thread.rootEventId(kind: kind, tags: tags).map(roots.contains)
                        ?? NIP10Thread.parentEventId(kind: kind, tags: tags).map(roots.contains)
                        ?? false
                    guard inThread, seen.insert(id).inserted else { return nil }
                    return FeedNote(id: id, pubkey: pubkey, content: content,
                                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                                    tags: tags, kind: kind)
                }
                if !replies.isEmpty { self.feedThreadReplies.append(contentsOf: replies) }
                if !replies.isEmpty {
                    let missing = Set(replies.map(\.pubkey)).filter { NostrService.shared.profiles[$0] == nil }
                    if !missing.isEmpty { NostrService.shared.fetchMissingProfiles(for: Array(missing)) }
                }
            }
        }
    }
}
