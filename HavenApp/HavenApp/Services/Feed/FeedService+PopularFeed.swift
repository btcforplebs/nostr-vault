import Foundation
import Combine
import SwiftUI

extension FeedService {
    // MARK: - Popular Feed (Local DVM)

    /// Query the local Go DVM for popular notes. The Go backend fetches
    /// engagement data (reactions, reposts, zaps) from seed relays, scores
    /// notes by popularity, and returns the top results.
    /// "No popular notes found" is wrong while the trust graph is still being
    /// built: the relay is withholding the feed on purpose, and there is
    /// something to wait for.
    private func popularEmptyStatus() -> String {
        curatedGraphReady ? "No popular notes found" : curatedGraphPendingStatus
    }

    func loadPopularFeed() {
        guard !isLoadingPopular else { return }
        isLoadingPopular = true
        isLoadingFeed = true
        shouldScrollToTopOnLoad = true
        connectionStatus = "Discovering popular notes..."
        notes.removeAll()
        popularNoteScores.removeAll()
        resetFeedThreadReplies()
        recomputeFilteredNotes()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let resultPtr = ComputePopularNotesC() else {
                DispatchQueue.main.async {
                    self?.isLoadingPopular = false
                    self?.isLoadingFeed = false
                    self?.connectionStatus = "No popular notes found"
                }
                return
            }
            let jsonString = String(cString: resultPtr)

            // Check for error response
            if let errorData = jsonString.data(using: .utf8),
               let errorObj = try? JSONSerialization.jsonObject(with: errorData) as? [String: String],
               let errorMsg = errorObj["error"] {
                DispatchQueue.main.async {
                    self?.isLoadingPopular = false
                    self?.isLoadingFeed = false
                    self?.connectionStatus = "Error: \(errorMsg)"
                }
                return
            }

            // Parse popular notes
            guard let data = jsonString.data(using: .utf8),
                  let popularNotes = try? JSONDecoder().decode([PopularNoteResult].self, from: data) else {
                DispatchQueue.main.async {
                    self?.isLoadingPopular = false
                    self?.isLoadingFeed = false
                    self?.connectionStatus = "Failed to parse results"
                }
                return
            }

            // Convert to FeedNote and build score map
            var feedNotes: [FeedNote] = []
            var scores: [String: Double] = [:]
            for pn in popularNotes {
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
                guard let self = self, self.feedMode == .popular else { return }
                self.notes = feedNotes
                self.popularNoteScores = scores
                self.isLoadingPopular = false
                self.isLoadingFeed = false
                self.connectionStatus = feedNotes.isEmpty ? self.popularEmptyStatus() : "Live"
                if feedNotes.isEmpty && !self.curatedGraphReady {
                    self.pollForCuratedGraph()
                }
                self.recomputeFilteredNotes()
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
    /// Global's replies pass the same trust rule as its posts, or a trusted
    /// post would carry the open firehose in underneath it.
    func loadFeedThreadReplies(rootIds: [String]) {
        guard feedMode == .popular || feedMode == .global else { return }
        let trusted = feedMode == .global ? globalTrustSet() : nil
        let wanted = rootIds.filter { !threadRepliesRequested.contains($0) }
        guard !wanted.isEmpty else { return }
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
                          !blocked.contains(pubkey), trusted?.contains(pubkey) ?? true,
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
