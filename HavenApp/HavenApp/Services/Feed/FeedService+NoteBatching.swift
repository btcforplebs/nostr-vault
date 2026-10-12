import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Called on processingQueue — parses JSON off the main thread, accumulates in background buffers.
    /// A periodic flush delivers batched results to the main thread.
    nonisolated func handleFeedMsgBackground(_ msg: String, totalRelays: Int) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            // Only count EOSE from the primary feed subscription (prefix "feed-"),
            // not auxiliary subs (mentions "m-", reactions "rx-", zaps "zaps-")
            // which would inflate the count and end loading prematurely.
            let subId = json.count >= 2 ? json[1] as? String : nil
            let isPrimaryFeed = subId?.hasPrefix("feed-") == true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if isPrimaryFeed {
                    self.eoseCount += 1

                    // Dispatch deferred auxiliary subscriptions now that
                    // this relay's primary feed content has arrived.
                    if let subId = subId,
                       let relayKey = self.subIdToRelayKey[subId],
                       !self.primaryEoseRelays.contains(relayKey),
                       let client = self.feedClients[relayKey] {
                        self.primaryEoseRelays.insert(relayKey)
                        self.sendAuxiliarySubscriptions(client: client, label: relayKey)
                    }
                }
                if self.eoseCount >= totalRelays {
                    self.feedLoadingTimeout?.invalidate()
                    self.drainBackgroundBuffers()
                    self.flushNoteBuffer()
                    self.isLoadingFeed = false
                    self.isSyncing = false
                    self.connectionStatus = "Live"
                    self.processingQueue.async { [weak self] in
                        self?.bgAccumulator.isInitialLoad = false
                    }
                }
            }
            return
        }

        // Intercept parent-note fetch responses from reused active connections.
        // These come back on the permanent feed pipeline but belong to the fast-path
        // handler so they appear in the thread preview immediately, bypassing the
        // 0.8 s note-flush timer.
        if type == "EVENT", json.count >= 2,
           let subId = json[1] as? String, subId.hasPrefix("tfetch-") {
            guard let ev = verifiedParentEvent(msg) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.handleParentNoteFetch(ev)
            }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let ev = json[2] as? [String: Any],
              let id        = ev["id"]         as? String,
              let pubkey    = ev["pubkey"]      as? String,
              let content   = ev["content"]     as? String,
              let createdAt = ev["created_at"]  as? Int64,
              let kind      = ev["kind"]        as? Int,
              let tags      = ev["tags"]        as? [[String]]
        else { return }

        // Ignore events with future timestamps (> 60 seconds in the future) to prevent feed corruption
        if Double(createdAt) > Date().timeIntervalSince1970 + 60 {
            return
        }

        // Comments on videos, articles and other kinds are not note threads.
        if kind == NIP10Thread.commentKind && !NIP10Thread.isNoteComment(kind: kind, tags: tags) {
            return
        }

        // Your own deletion requests, from this device or another.
        if kind == DeletedNotes.requestKind {
            handleDeleteRequest(pubkey: pubkey, tags: tags)
            return
        }

        // Handle Reactions (Kind 7) — track for self-like detection + per-note counting
        if kind == 7 {
            if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                let acc = self.bgAccumulator
                let reaction = EngagementTracker.ReactionEvent(
                    targetId: targetId, pubkey: pubkey, eventId: id,
                    content: ev["content"] as? String ?? "")
                processingQueue.async { [weak self] in
                    // Deduplicate reactions from multiple relays
                    guard !acc.seenEngagementIds.contains(reaction.eventId) else { return }
                    acc.seenEngagementIds.insert(reaction.eventId)
                    acc.reactionEvents.append(reaction)
                    self?.scheduleBackgroundFlush()
                }
            }
            return
        }

        // Handle Zap Receipts (Kind 9735) and Zap Requests (Kind 9734)
        // Forward to NostrService so ViewerView can access them via nostrService.events
        if kind == 9735 || kind == 9734 {
            if let evData = try? JSONSerialization.data(withJSONObject: ev),
               let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                DispatchQueue.main.async {
                    if kind == 9735 {
                        guard let recipientPubkey = tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] else { return }
                        Task {
                            guard await ZapValidationService.isValidReceipt(pubkey: pubkey, recipientPubkey: recipientPubkey) else { return }
                            NostrService.shared.injectEvent(event)
                        }
                    } else {
                        NostrService.shared.injectEvent(event)
                    }
                }
            }
            return
        }

        // FeedNote.init handles kind 6 JSON embedding internally: it swaps to the inner
        // author/content/tags and sets repostedBy. Passing the raw event through is enough.
        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind,
            repostedBy: kind == 6 ? pubkey : nil
        )

        // Filter out obvious spam/noise from being processed. A repost that
        // only points at the original (empty content plus an `e` tag) is valid
        // NIP-18 and the row fetches what it points at — but the empty-content
        // rule threw it away: 2 of the 9 notes missing from two hours of a
        // Following feed on 2026-10-04 were these.
        let isBareRepost = note.kind == 6 && note.content.isEmpty && note.repostedEventId != nil
        if !isBareRepost, FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) {
            return
        }

        // NIP-18: Cache raw event JSON for repost embedding.
        // For kind 1/30023: serialize the full event dict (includes sig).
        // For kind 6 with embedded content: the content IS the inner event's JSON.
        var rawEntries: [(id: String, json: String)] = []
        if kind == 1 || kind == 30023 || kind == NIP10Thread.commentKind || kind == NIP88Poll.kind {
            if let data = try? JSONSerialization.data(withJSONObject: ev, options: []),
               let json = String(data: data, encoding: .utf8) {
                rawEntries.append((id: id, json: json))
            }
        }
        if kind == 6, !content.isEmpty,
           let innerData = content.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
           let innerId = inner["id"] as? String {
            rawEntries.append((id: innerId, json: content))
        }

        // Accumulate on processing queue — NO per-event main thread dispatch
        let acc = self.bgAccumulator
        processingQueue.async { [weak self] in
            acc.notes.append(note)
            acc.profiles.append(pubkey)
            acc.rawEventEntries.append(contentsOf: rawEntries)
            // After FeedNote.init swaps for kind 6 reposts, note.pubkey is the original author.
            // Fetch their profile too so the reposted card renders with the right name/avatar.
            if note.pubkey != pubkey { acc.profiles.append(note.pubkey) }

            // Track engagement: reposts (kind 6)
            if kind == 6 {
                if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    acc.repostTargets.append(targetId)
                }
            }

            // Parents are prefetched in applySnapshot (proactive, so they arrive before
            // the child row appears). Repost/quoted fetches still happen on onAppear.
            self?.scheduleBackgroundFlush()
        }
    }

    /// Schedule a single coalesced flush of the background buffers → main thread.
    /// Must be called on processingQueue.
    private nonisolated func scheduleBackgroundFlush() {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        let acc = bgAccumulator
        guard !acc.flushScheduled else { return }
        acc.flushScheduled = true
        processingQueue.asyncAfter(deadline: .now() + acc.effectiveFlushInterval) { [weak self] in
            self?.deliverBackgroundBatch()
        }
    }

    /// Take everything accumulated on the processing queue and deliver it to main in one dispatch.
    private nonisolated func deliverBackgroundBatch() {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        let snap = bgAccumulator.drain()

        guard !snap.notes.isEmpty || !snap.reactionEvents.isEmpty || !snap.repostTargets.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.applySnapshot(snap)
        }
    }

    /// Force-drain background buffers synchronously (called on main before EOSE flush).
    private func drainBackgroundBuffers() {
        let acc = bgAccumulator
        var snap: BackgroundAccumulator.Snapshot!
        processingQueue.sync {
            snap = acc.drain()
        }
        applySnapshot(snap)
    }

    /// Apply a drained snapshot to main-actor state.
    private func applySnapshot(_ snap: BackgroundAccumulator.Snapshot) {
        var added = false
        var parentIdsToFetch: [String] = []
        var referencedAuthors = Set<String>()
        for note in snap.notes {
            guard !seenIds.contains(note.id), !hidesDeleted(note) else { continue }
            seenIds.insert(note.id)
            noteBuffer.append(note)
            added = true
            let ts = Int64(note.createdAt.timeIntervalSince1970)
            if ts > lastEventTimestamp {
                lastEventTimestamp = ts
            }
            // Prefetch parents proactively so they're cached before the row scrolls
            // into view — otherwise the child renders before the parent arrives.
            if let parentId = note.parentEventId {
                parentIdsToFetch.append(parentId)
            }
            if noteRelayHints.count > 5000 { noteRelayHints.removeAll() }
            if noteAuthorHints.count > 5000 { noteAuthorHints.removeAll() }
            for tag in note.tags where tag.count >= 2 && tag[0] == "e" {
                if tag.count >= 3, tag[2].hasPrefix("wss://") {
                    noteRelayHints[tag[1]] = URL(string: tag[2])
                }
                if tag.count >= 5, tag[4].count == 64 {
                    noteAuthorHints[tag[1]] = tag[4]
                }
            }
            // Older clients leave the e-tag pubkey slot empty; the direct
            // parent's author is then the reply's p-tag.
            if let parentId = note.parentEventId, noteAuthorHints[parentId] == nil,
               let replyTo = note.replyToPubkey {
                noteAuthorHints[parentId] = replyTo
            }
            for tag in note.tags where tag.count >= 2 && tag[0] == "e" {
                if let author = noteAuthorHints[tag[1]] { referencedAuthors.insert(author) }
            }
            // The thread root too: a deep reply's parent is not its root, and
            // threaded mode heads the card with the root. Waiting to walk the
            // chain one fetch at a time left cards on "Loading the start of
            // this thread…" for a second each.
            if let rootId = note.tags.first(where: { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" })?[1],
               rootId != note.parentEventId {
                parentIdsToFetch.append(rootId)
            }
        }
        trimSeenIdsIfNeeded()

        // Load the referenced authors' relay lists before the fetch flushes,
        // so its first pass can already ask their own relays.
        requestRelayLists(for: referencedAuthors)
        for parentId in parentIdsToFetch {
            fetchMissingNote(id: parentId)
        }

        let uniquePubkeys = Set(snap.profiles).subtracting(Set(NostrService.shared.profiles.keys))
        if !uniquePubkeys.isEmpty {
            NostrService.shared.fetchMissingProfiles(for: Array(uniquePubkeys))
        }

        // Process reaction events: self-like detection + per-note counting
        let hasEngagement = !snap.reactionEvents.isEmpty || !snap.repostTargets.isEmpty
        if hasEngagement {
            let ownerHex = NostrService.shared.activeHexPubkey

            // Self-likes: reactions authored by the owner
            let selfReactions = EngagementTracker.detectSelfReactions(
                reactions: snap.reactionEvents, ownerHex: ownerHex, retracted: retractedReactionIds)
            if !selfReactions.isEmpty {
                let before = likedEventIds.count
                likedEventIds.formUnion(selfReactions.keys)
                var changed = likedEventIds.count > before
                // Only fills in notes with no known reaction. One made here
                // (signed, or still signing) is the one to show and to delete
                // on removal; an older echo of a replaced one must not win.
                for (noteId, rx) in selfReactions where myReactions[noteId] == nil {
                    myReactions[noteId] = rx
                    changed = true
                }
                if changed {
                    saveInteractionState()
                }
            }

            // Merge engagement counts (single dictionary assignment for one @Published update)
            noteStats = EngagementTracker.mergeEngagementCounts(
                reactions: snap.reactionEvents,
                repostTargets: snap.repostTargets,
                currentStats: noteStats,
                retracted: retractedReactionIds
            )
        }

        // Merge raw event JSON entries into the cache for NIP-18 repost embedding.
        // Must go through cacheRawEvent so the FIFO order array stays in sync
        // (it also enforces the size cap).
        for entry in snap.rawEventEntries {
            cacheRawEvent(id: entry.id, json: entry.json)
        }

        if added {
            scheduleNoteFlush()
        }
    }

    private func scheduleNoteFlush() {
        guard noteFlushTimer == nil else { return }
        // Global feed uses ultra-fast flushing for real-time streaming feel
        let interval: TimeInterval = isGlobalLikeMode ? 0.05 : 0.8
        noteFlushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushNoteBuffer()
            }
        }
    }

    func flushNoteBuffer() {
        noteFlushTimer?.invalidate()
        noteFlushTimer = nil
        guard !noteBuffer.isEmpty else { return }

        let batch = noteBuffer
        noteBuffer.removeAll(keepingCapacity: true)

        // A post that arrives through the feed itself can be the parent (or
        // repost original, or quote) another row is waiting on. Only fetched
        // parents used to signal, so those rows kept their loading skeleton
        // until something unrelated rebuilt them, though the note was here.
        for note in batch { noteReferencedNoteArrived(note.id) }

        // Prefetch media content types for the batch — moves HTTP HEAD detection
        // out of the rendering path so FeedMediaView has cached types when it renders.
        // Cap at 50 URLs per flush to avoid excessive HTTP HEAD requests in the background.
        let allMediaURLs = Array(batch.flatMap { $0.mediaURLs }.prefix(50))
        if !allMediaURLs.isEmpty {
            MediaTypeDetector.shared.prefetchContentTypes(for: allMediaURLs)
        }

        // During initial load, add everything at once then sort once.
        // Build the array locally to avoid multiple @Published mutations
        // (each triggers objectWillChange and a SwiftUI body re-evaluation).
        if notes.isEmpty || isLoadingFeed {
            var updated = notes
            updated.append(contentsOf: batch)
            updated.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
            if updated.count > Self.maxNotes {
                updated.removeLast(updated.count - Self.maxNotes)
            }
            notes = updated  // single @Published assignment
            recomputeFilteredNotes()
            return
        }

        // Live updates: buffer new top-level notes to prevent feed jumping
        let newestDate = notes.first?.createdAt ?? Date.distantPast
        let driftThreshold = newestDate.addingTimeInterval(-60) // 60 seconds grace period for relay clock drift

        var toAdd: [FeedNote] = []
        var toPending: [FeedNote] = []

        for note in batch {
            if note.createdAt > driftThreshold && !note.isReply {
                // Always buffer new top-of-feed notes as pending to prevent
                // scroll disruption. FeedView auto-applies them when autoLoad is on.
                toPending.append(note)
            } else {
                toAdd.append(note)
            }
        }

        if !toAdd.isEmpty {
            // Build locally, assign once to minimize objectWillChange notifications
            var updated = notes
            updated.append(contentsOf: toAdd)
            updated.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
            if updated.count > Self.maxNotes {
                updated.removeLast(updated.count - Self.maxNotes)
            }
            notes = updated
        }

        if !toPending.isEmpty {
            let updatedPending = pendingNotes + toPending
            let uniqueMap = Dictionary(updatedPending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var sorted = uniqueMap.values.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
            // Drop oldest pending notes to prevent unbounded memory growth
            if sorted.count > Self.maxPendingNotes {
                sorted.removeLast(sorted.count - Self.maxPendingNotes)
            }
            pendingNotes = sorted
        }

        if !toAdd.isEmpty {
            recomputeFilteredNotes()
        }

        trimEngagementStateIfNeeded()
    }

    /// Trim noteStats to only contain entries for notes currently in memory.
    /// Called after notes are flushed to prevent unbounded growth of engagement data.
    private func trimEngagementStateIfNeeded() {
        guard noteStats.count > Self.maxNotes else { return }
        let activeIds = Set(notes.map { $0.id }).union(parentNotesCache.keys)
        noteStats = noteStats.filter { activeIds.contains($0.key) }
    }
}
