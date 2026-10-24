import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Rebuild the O(1) note lookup dictionary from the current `notes` array.
    private func rebuildNoteIndex() {
        noteIndex = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Recompute the cached filtered-notes arrays. Called after any mutation to
    /// `notes`, `feedMode`, or relevant config (showReposts / showReplies / blocked).
    func recomputeFilteredNotes() {
        rebuildNoteIndex()
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        // Your web with today's follows, so a follow passes Global at once.
        let trusted = feedTrustedPubkeys

        let newFiltered = FeedFilterEngine.filterFeedNotes(
            notes: notes,
            mode: feedMode,
            articlesGlobal: articlesFeedMode == .global,
            pollsGlobal: pollsFeedMode == .global,
            pollStatus: pollStatusFilter,
            blocked: blocked,
            showReposts: ConfigService.shared.config.showReposts,
            showReplies: ConfigService.shared.config.showReplies,
            followedPubkeys: followedPubkeys,
            ownPubkey: NostrService.shared.activeHexPubkey,
            wotPubkeys: trusted,
            popularFilter: popularFilter,
            popularNoteScores: popularNoteScores,
            globalLanguages: Set(ConfigService.shared.config.globalFeedLanguages),
            globalRequiresTrust: !ConfigService.shared.config.globalShowsEveryone,
            languageOf: { [unowned self] note in self.language(of: note) },
            authorOf: { [unowned self] id in self.findNote(id: id)?.pubkey }
        )

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

        let newMedia = FeedFilterEngine.filterMediaNotes(
            notes: notes,
            blocked: blocked,
            wotPubkeys: trusted,
            isGlobalMedia: feedMode == .media && mediaFeedMode == .global,
            globalRequiresTrust: !ConfigService.shared.config.globalShowsEveryone,
            authorOf: { [unowned self] id in self.findNote(id: id)?.pubkey }
        )

        if newMedia.count != filteredMediaNotes.count ||
            !zip(newMedia, filteredMediaNotes).allSatisfy({ $0.id == $1.id }) {
            filteredMediaNotes = newMedia
        }
        refreshVisiblePendingCount()
    }

    /// Re-counts `visiblePendingCount` through the current feed's filter.
    /// Runs when the pending list changes and on every recompute, which is
    /// where the filter's inputs (mode, trust graph, blocked, settings) land.
    func refreshVisiblePendingCount() {
        let count: Int
        if pendingNotes.isEmpty {
            count = 0
        } else {
            let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
            let authorOf: (String) -> String? = { [unowned self] id in self.findNote(id: id)?.pubkey }
            if feedMode == .media {
                count = FeedFilterEngine.filterMediaNotes(
                    notes: pendingNotes,
                    blocked: blocked,
                    wotPubkeys: feedTrustedPubkeys,
                    isGlobalMedia: mediaFeedMode == .global,
                    globalRequiresTrust: !ConfigService.shared.config.globalShowsEveryone,
                    authorOf: authorOf
                ).count
            } else {
                count = FeedFilterEngine.filterFeedNotes(
                    notes: pendingNotes,
                    mode: feedMode,
                    articlesGlobal: articlesFeedMode == .global,
                    pollsGlobal: pollsFeedMode == .global,
                    pollStatus: pollStatusFilter,
                    blocked: blocked,
                    showReposts: ConfigService.shared.config.showReposts,
                    showReplies: ConfigService.shared.config.showReplies,
                    followedPubkeys: followedPubkeys,
                    ownPubkey: NostrService.shared.activeHexPubkey,
                    wotPubkeys: feedTrustedPubkeys,
                    popularFilter: popularFilter,
                    popularNoteScores: popularNoteScores,
                    globalLanguages: Set(ConfigService.shared.config.globalFeedLanguages),
                    globalRequiresTrust: !ConfigService.shared.config.globalShowsEveryone,
                    languageOf: { [unowned self] note in self.language(of: note) },
                    authorOf: authorOf
                ).count
            }
        }
        if count != visiblePendingCount { visiblePendingCount = count }
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
