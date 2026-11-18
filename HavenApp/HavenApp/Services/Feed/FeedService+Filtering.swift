import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Rebuild the O(1) note lookup dictionary from the current `notes` array.
    private func rebuildNoteIndex() {
        noteIndex = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Underrated's list cut to the pages asked for so far (50 at a time);
    /// every other feed whole.
    private func pagedDvmNotes(_ all: [FeedNote]) -> [FeedNote] {
        let pageSize = feedMode.localDvm?.pageSize
        dvmFilteredTotal = all.count
        let shown = LocalDvmFeed.shownCount(total: all.count, revealed: dvmRevealed, pageSize: pageSize)
        let hasMore = shown < all.count
        if dvmHasMore != hasMore { dvmHasMore = hasMore }
        return shown < all.count ? Array(all.prefix(shown)) : all
    }

    /// Shows Underrated's next 50, when the end of the list is reached.
    /// Returns false when there is nothing more to show.
    @discardableResult
    func revealMoreDvmNotes() -> Bool {
        guard let next = LocalDvmFeed.nextRevealed(total: dvmFilteredTotal, revealed: dvmRevealed,
                                                   pageSize: feedMode.localDvm?.pageSize) else { return false }
        dvmRevealed = next
        recomputeFilteredNotes()
        return true
    }

    /// Recompute the cached filtered-notes arrays. Called after any mutation to
    /// `notes`, `feedMode`, or relevant config (showReposts / showReplies / blocked).
    func recomputeFilteredNotes() {
        rebuildNoteIndex()
        // The one gate: the open account's web, blocks and mutes, read once.
        let gate = feedGate
        let newFiltered = pagedDvmNotes(feedFiltered(notes, gate: gate))

        // Only publish a change when the visible list actually differs.
        // Uses lazy zip to avoid allocating temporary [String] arrays.
        if newFiltered.count != filteredNotes.count ||
            !zip(newFiltered, filteredNotes).allSatisfy({ $0.id == $1.id }) {
            #if DEBUG
            if newFiltered.isEmpty && !notes.isEmpty {
                print("FeedService: [recompute] ⚠️ filtered→0 with notes=\(notes.count) mode=\(feedMode.rawValue) followedPubkeys=\(followedPubkeys.count)")
            }
            #endif
            filteredNotes = newFiltered
            parentIsNextNote = FeedFilterEngine.computeParentIsNext(filteredNotes: newFiltered)
        }

        let newMedia = mediaFiltered(notes, gate: gate)
        if newMedia.count != filteredMediaNotes.count ||
            !zip(newMedia, filteredMediaNotes).allSatisfy({ $0.id == $1.id }) {
            filteredMediaNotes = newMedia
        }

        // Global lists ask for no notes tagging you, so they have nothing to fold.
        let outside = isGlobalLikeMode ? [] : FeedFilterEngine.outsideMentions(
            notes: notes, gate: gate, owner: NostrService.shared.activeHexPubkey,
            authorOf: { [unowned self] id in self.findNote(id: id)?.pubkey })
        if outside.map(\.id) != feedOutsideMentions.map(\.id) { feedOutsideMentions = outside }
        refreshVisiblePendingCount(gate: gate)
    }

    /// Re-counts `visiblePendingCount` through the current feed's filter.
    /// Runs when the pending list changes and on every recompute, which is
    /// where the filter's inputs (mode, trust graph, blocked, settings) land.
    func refreshVisiblePendingCount(gate: WebGate.Web? = nil) {
        let count: Int
        if pendingNotes.isEmpty {
            count = 0
        } else {
            let gate = gate ?? feedGate
            count = feedMode == .media ? mediaFiltered(pendingNotes, gate: gate).count
                : feedFiltered(pendingNotes, gate: gate).count
        }
        if count != visiblePendingCount { visiblePendingCount = count }
    }

    /// The current feed's filter over `list`, through the gate.
    private func feedFiltered(_ list: [FeedNote], gate: WebGate.Web) -> [FeedNote] {
        let config = ConfigService.shared.config
        return FeedFilterEngine.filterFeedNotes(
            notes: list,
            mode: feedMode,
            articlesGlobal: articlesFeedMode == .global,
            pollsGlobal: pollsFeedMode == .global,
            pollStatus: pollStatusFilter,
            gate: gate,
            reach: currentReach,
            showReposts: config.showReposts,
            showReplies: config.showReplies,
            followedPubkeys: followedPubkeys,
            ownPubkey: NostrService.shared.activeHexPubkey,
            popularFilter: popularFilter,
            popularNoteScores: popularNoteScores,
            globalLanguages: Set(config.globalFeedLanguages),
            languageOf: { [unowned self] note in self.language(of: note) },
            authorOf: { [unowned self] id in self.findNote(id: id)?.pubkey }
        )
    }

    /// The media grid's filter over `list`, through the gate.
    private func mediaFiltered(_ list: [FeedNote], gate: WebGate.Web) -> [FeedNote] {
        FeedFilterEngine.filterMediaNotes(
            notes: list,
            gate: gate,
            reach: reach(for: .media, globalLike: mediaFeedMode == .global),
            authorOf: { [unowned self] id in self.findNote(id: id)?.pubkey }
        )
    }

    private func language(of note: FeedNote) -> String? {
        if let cached = noteLanguageCache[note.id] { return cached }
        // Bounded well above the 800-note feed cap; a reset just re-detects.
        if noteLanguageCache.count > 4000 { noteLanguageCache.removeAll(keepingCapacity: true) }
        let detected = FeedLanguageDetector.detect(FeedLanguageDetector.text(of: note.content, kind: note.kind))
        noteLanguageCache[note.id] = .some(detected)
        return detected
    }

    var isGlobalLikeMode: Bool {
        feedMode == .global
            || (feedMode == .media && mediaFeedMode == .global)
            || (feedMode == .articles && articlesFeedMode == .global)
            || (feedMode == .polls && pollsFeedMode == .global)
    }
}
