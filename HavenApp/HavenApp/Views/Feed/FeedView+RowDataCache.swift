import SwiftUI

extension FeedView {
    // MARK: - Row Data Cache

    /// Rebuild the per-row data cache for all currently visible filtered notes.
    /// Called when the underlying data changes (notes, likes, profiles, etc.)
    /// so the ForEach loop can reuse cached values instead of calling resolve()
    /// on every unrelated SwiftUI re-render.
    ///
    /// This method is debounced to prevent expensive synchronous operations
    /// during active scrolling, especially when scrolling to the top triggers
    /// auto-loading of pending notes.
    /// Regroup the feed into conversations. A no-op unless threaded mode is on,
    /// and debounced like the row-data cache so a burst of arriving notes
    /// doesn't regroup the timeline once per note.
    func rebuildThreadsIfNeeded(immediate: Bool = false) {
        // The Hashtags feed groups its own two sections (HashtagsFeedSection).
        guard isThreadedModeActive, feedService.feedMode != .hashtags else {
            threadRebuildWork?.cancel()
            if !feedThreads.isEmpty { feedThreads = [] }
            return
        }

        threadRebuildWork?.cancel()
        let work = DispatchWorkItem { [self] in
            let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
            // Popular and Global hold only top-level posts, so their replies
            // are fetched separately for this view, and the feed's own order
            // is kept: a reply landing later doesn't reshuffle the posts.
            let fetchesReplies = feedService.feedMode == .popular || feedService.feedMode == .global
            if fetchesReplies {
                feedService.loadFeedThreadReplies(rootIds: feedService.filteredNotes.map(\.id))
            }
            let notes = fetchesReplies ? feedService.filteredNotes + feedService.feedThreadReplies : feedService.filteredNotes
            feedThreads = FeedThreadGrouping.build(notes: notes, keepFeedOrder: fetchesReplies) { id in
                // Ancestors the timeline never showed still live in the feed
                // service's caches; pulling them in keeps a conversation whole.
                // A blocked author's post is never pulled in as context.
                guard let note = feedService.findNote(id: id),
                      !blocked.contains(note.pubkey) else { return nil }
                return note
            }.filter { thread in
                // A conversation started by a blocked author goes entirely.
                // Its root is withheld above, so without this the card would
                // sit on "Loading the start of this thread…" forever.
                guard thread.root == nil,
                      let root = feedService.findNote(id: thread.rootId) else { return true }
                return !blocked.contains(root.pubkey)
            }
            // Ask for every missing root now, in one batch, rather than from
            // each card's onAppear: a fast scroll reaches cards faster than a
            // relay round trip, so each one sat on its loading header.
            // fetchMissingNote dedupes, so a rebuild re-asks nothing in flight.
            for thread in feedThreads where thread.root == nil {
                feedService.fetchMissingNote(id: thread.rootId)
            }
        }
        threadRebuildWork = work

        if immediate {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    func rebuildRowDataCache(immediate: Bool = false) {
        // Cancel any pending rebuild to avoid redundant work
        cacheRebuildWork?.cancel()

        let work = DispatchWorkItem { [self] in
            var newCache: [String: FeedNoteRowData] = [:]
            newCache.reserveCapacity(feedService.filteredNotes.count)
            for note in feedService.filteredNotes {
                newCache[note.id] = FeedNoteRowData.resolve(
                    for: note,
                    feedService: feedService,
                    nostrService: nostrService
                )
            }
            rowDataCache = newCache
        }

        cacheRebuildWork = work

        if immediate {
            // Execute immediately for initial load
            work.perform()
        } else {
            // Use a short delay to batch multiple rapid changes together.
            // During scrolling, this prevents blocking the main thread.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    // MARK: - Incremental row-data cache updates
    //
    // `rebuildRowDataCache` (above) re-resolves EVERY visible note and is kept
    // only for the initial on-appear build. Steady-state changes (a like, a zap,
    // one profile arriving) used to trigger that full rebuild too — re-resolving
    // up to 800 rows to reflect a one-row change, ~100+ times during boot as
    // profile metadata streams in one pubkey at a time. The handlers below update
    // only the rows that actually changed. `resolve()` is reused verbatim, so the
    // resulting rowData is identical to a full rebuild.

    /// Reconcile the cache against `filteredNotes` after the visible set changes:
    /// keep entries for notes still present, resolve only newly-added notes, drop
    /// removed ones, and repair rows whose parent / reposted-original dependency
    /// has just arrived (the only way an existing row's resolved data can change
    /// without its own id changing). Debounced like the full rebuild.
    func reconcileRowDataCache() {
        cacheRebuildWork?.cancel()
        let work = DispatchWorkItem { [self] in
            let notes = feedService.filteredNotes
            var newCache: [String: FeedNoteRowData] = [:]
            newCache.reserveCapacity(notes.count)
            for note in notes {
                if let existing = rowDataCache[note.id] {
                    // A previously-unresolved cross-note dependency (the parent
                    // note, or a kind-6 repost's original) may now resolve.
                    let needsParent = note.parentEventId != nil && existing.parentNote == nil
                    let needsOriginal = note.kind == 6 && note.content.isEmpty
                        && note.repostedEventId != nil && existing.resolvedOriginal == nil
                    if needsParent || needsOriginal {
                        newCache[note.id] = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
                    } else {
                        newCache[note.id] = existing
                    }
                } else {
                    newCache[note.id] = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
                }
            }
            rowDataCache = newCache
        }
        cacheRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Re-resolve only the cached rows whose id is in `ids`. Reassigns the cache
    /// (triggering a SwiftUI update) only if something actually changed —
    /// `FeedNoteRowData: Equatable` makes that comparison free.
    private func resolveRows(matching ids: Set<String>) {
        guard !ids.isEmpty else { return }
        // A repost row shows its original's likes, zaps and counts, which are
        // keyed by the original's id, not the row's.
        var ids = ids
        for note in feedService.filteredNotes where note.kind == 6 {
            if let refId = note.repostedEventId, ids.contains(refId) { ids.insert(note.id) }
        }
        var updated = rowDataCache
        var didChange = false
        for id in ids {
            guard rowDataCache[id] != nil, let note = feedService.findNote(id: id) else { continue }
            let resolved = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
            if updated[id] != resolved {
                updated[id] = resolved
                didChange = true
            }
        }
        if didChange { rowDataCache = updated }
    }

    /// likedEventIds is keyed by `note.id`, so the symmetric difference is exactly
    /// the set of affected rows.
    func updateRowDataForLikes(old: Set<String>, new: Set<String>) {
        resolveRows(matching: old.symmetricDifference(new))
    }

    /// myReactions is keyed by `note.id`: a changed emoji leaves likedEventIds
    /// alone, so it needs its own refresh.
    func updateRowDataForMyReactions(old: [String: EngagementTracker.MyReaction],
                                             new: [String: EngagementTracker.MyReaction]) {
        var changed = Set<String>()
        for (id, rx) in new where old[id]?.content != rx.content { changed.insert(id) }
        for id in old.keys where new[id] == nil { changed.insert(id) }
        resolveRows(matching: changed)
    }

    /// zappedEventIds is a `[noteID: amount]` dict; collect ids whose amount was
    /// added, removed, or changed.
    func updateRowDataForZaps(old: [String: Int], new: [String: Int]) {
        var changed = Set<String>()
        for (id, amount) in new where old[id] != amount { changed.insert(id) }
        for id in old.keys where new[id] == nil { changed.insert(id) }
        resolveRows(matching: changed)
    }

    /// repostedEventIds is keyed by `repostCheckId = repostedEventId ?? id`, which
    /// differs from `note.id` for kind-6 repost rows. Map the changed keys back to
    /// the affected row ids with the same expression `resolve()` uses.
    func updateRowDataForReposts(old: Set<String>, new: Set<String>) {
        let changedKeys = old.symmetricDifference(new)
        guard !changedKeys.isEmpty else { return }
        var ids = Set<String>()
        for note in feedService.filteredNotes {
            let repostCheckId = note.repostedEventId ?? note.id
            if changedKeys.contains(repostCheckId) { ids.insert(note.id) }
        }
        resolveRows(matching: ids)
    }

    /// A batch of profiles changed. Re-resolve only rows that reference any of
    /// those pubkeys as author, displayPubkey, parent author, reposter, or
    /// replyTo — every profile-dependent field `resolve()` reads.
    func refreshRowsForPubkeys(_ pubkeys: Set<String>) {
        guard !pubkeys.isEmpty else { return }
        var ids = Set<String>()
        for note in feedService.filteredNotes {
            if pubkeys.contains(note.pubkey)
                || (note.repostedBy.map(pubkeys.contains) ?? false)
                || (note.replyToPubkey.map(pubkeys.contains) ?? false) {
                ids.insert(note.id)
                continue
            }
            // parent author
            if let parentId = note.parentEventId,
               let parent = feedService.findNote(id: parentId),
               pubkeys.contains(parent.pubkey) {
                ids.insert(note.id)
                continue
            }
            // kind-6 repost: original author drives displayPubkey/displayProfile
            if note.kind == 6, note.content.isEmpty,
               let refId = note.repostedEventId,
               let original = feedService.findNote(id: refId),
               pubkeys.contains(original.pubkey) {
                ids.insert(note.id)
            }
        }
        resolveRows(matching: ids)
    }

    /// Referenced notes (thread parents, kind-6 originals, quoted notes) just
    /// arrived — re-resolve only the rows that reference them, so the parent
    /// preview replaces its skeleton immediately instead of waiting for an
    /// unrelated change to force a rebuild.
    func refreshRowsForReferencedNotes(_ arrivedIds: Set<String>) {
        resolveRows(matching: ReferencedNoteRepair.rowsNeedingRepair(
            notes: feedService.filteredNotes, arrivedIds: arrivedIds))
    }

    /// A fetched ancestor changes the *shape* of the timeline, not just a row:
    /// the thread grouping is built from `filteredNotes` plus whatever
    /// `findNote` could resolve at the time, so a root that arrives afterwards
    /// is invisible to it until something else touches the note list. That is
    /// what left a thread card stuck on "Loading the start of this thread..."
    /// on a quiet feed — the root had arrived, nobody regrouped.
    ///
    /// Only a note that fills a gap in the current grouping can change it, so
    /// the rebuild is gated on that rather than run for every referenced note
    /// (quotes and repost originals arrive constantly and change nothing here).
    func regroupIfGapFilled(_ arrivedIds: Set<String>) {
        guard isThreadedModeActive, !arrivedIds.isEmpty else { return }
        var gapIds = Set(feedThreads.lazy.filter { $0.root == nil }.map(\.rootId))
        for note in feedService.filteredNotes {
            if let parentId = note.parentEventId { gapIds.insert(parentId) }
        }
        guard !arrivedIds.isDisjoint(with: gapIds) else { return }
        // Roots stream in every ~0.1 s while a feed fills, and each rebuild
        // regroups the whole feed on the main thread; per batch, that kept
        // the phone hot. Regroup at most every 0.4 s. A throttle, not a
        // debounce: a steady stream must not postpone the regroup forever.
        guard !gapRegroupScheduled else { return }
        gapRegroupScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            gapRegroupScheduled = false
            rebuildThreadsIfNeeded(immediate: true)
        }
    }

    /// noteStats changed — re-resolve rows whose stats actually differ.
    func updateRowDataForNoteStats(old: [String: NoteStats], new: [String: NoteStats]) {
        var changed = Set<String>()
        for (id, stats) in new where old[id] != stats { changed.insert(id) }
        resolveRows(matching: changed)
    }

    // MARK: - Auto-load debounce

    /// Schedules a debounced `applyPendingNotes()` call, cancelling any
    /// previously pending call so only one fires at a time.
    func scheduleAutoLoad(delay: Double) {
        autoLoadWork?.cancel()
        let work = DispatchWorkItem { [self] in
            guard !feedService.pendingNotes.isEmpty,
                  configService.config.autoLoadNewPosts,
                  isAtTop, expandedNoteId == nil else { return }
            feedService.applyPendingNotes()
        }
        autoLoadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Feed Actions (environment for FeedNoteRow)

    var feedActionsValue: FeedActions {
        .make(feedService: feedService, nostrService: nostrService)
    }
}
