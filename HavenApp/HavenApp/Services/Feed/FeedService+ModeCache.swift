import Foundation
import Combine
import SwiftUI

extension FeedService {
    private func modeCacheKey(_ mode: FeedMode) -> String {
        // The account the notes on screen were loaded for, as accountSnapshots
        // uses — not the live config, which can move first during a switch.
        let account = loadedSnapshotNpub.isEmpty ? currentSnapshotKey() : loadedSnapshotNpub
        var key = "\(account)|\(mode.rawValue)"
        if mode == .media { key += "|\(mediaFeedMode)" }
        if mode == .articles { key += "|\(articlesFeedMode)" }
        if mode == .polls { key += "|\(pollsFeedMode)" }
        return key
    }

    /// Feeds whose notes come through this service's own pipeline.
    static func usesNotePipeline(_ mode: FeedMode) -> Bool {
        switch mode {
        case .following, .discovery, .global, .popular, .media, .articles, .polls: return true
        default: return false
        }
    }

    func captureModeCache(for mode: FeedMode) {
        guard Self.usesNotePipeline(mode), !notes.isEmpty else { return }
        // Everything that was on screen, notes still waiting behind the "new
        // posts" pill, plus the newest raw notes. A filtered feed (Global keeps
        // only trusted authors) can show a handful out of hundreds, and the
        // newest 200 alone would drop what was visible.
        var kept = Set<String>()
        var cached: [FeedNote] = []
        for note in filteredNotes + pendingNotes + noteBuffer + notes.prefix(200) where kept.insert(note.id).inserted {
            cached.append(note)
        }
        cached.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
        modeCaches[modeCacheKey(mode)] = ModeFeedCache(
            notes: cached,
            parentNotesCache: parentNotesCache,
            noteStats: noteStats,
            popularNoteScores: popularNoteScores,
            capturedAt: Date()
        )
    }

    /// Puts a cached feed back on screen. Returns its age, or nil if there was
    /// nothing fresh enough to show.
    func restoreModeCache(for mode: FeedMode) -> TimeInterval? {
        let key = modeCacheKey(mode)
        guard let cache = modeCaches[key] else { return nil }
        let age = Date().timeIntervalSince(cache.capturedAt)
        guard age < Self.modeCacheMaxAge, !cache.notes.isEmpty else {
            modeCaches.removeValue(forKey: key)
            return nil
        }
        // A cache saved before a delete still holds the post.
        notes = withoutDeletedNotes(cache.notes)
        parentNotesCache = withoutDeletedNotes(cache.parentNotesCache)
        // Seen = exactly what was kept, and resume from the newest kept note:
        // anything dropped from the cache can then come back from relays
        // instead of being refused as already seen.
        seenIds = Set(cache.notes.map(\.id))
        noteStats = cache.noteStats
        popularNoteScores = cache.popularNoteScores
        lastEventTimestamp = cache.notes.map { Int64($0.createdAt.timeIntervalSince1970) }.max() ?? 0
        return age
    }

    /// Disconnects a side feed's service once it has gone unused for
    /// `sideFeedLinger`; coming back sooner cancels it.
    func scheduleSideFeedDisconnect(_ mode: FeedMode) {
        let disconnect: () -> Void
        switch mode {
        // A load still running finishes on its own timeout; cutting it off
        // would leave isLoading set and the next visit would never reload.
        case .recipes: disconnect = { if !RecipeFeedService.shared.isLoading { RecipeFeedService.shared.disconnect() } }
        case .marketplace: disconnect = { if !MarketplaceFeedService.shared.isLoading { MarketplaceFeedService.shared.disconnect() } }
        case .live: disconnect = { LiveFeedService.shared.disconnect() }
        case .reels: disconnect = { ReelsFeedService.shared.disconnect() }
        default: return
        }
        sideFeedDisconnects[mode]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.feedMode != mode else { return }
            self.sideFeedDisconnects[mode] = nil
            disconnect()
        }
        sideFeedDisconnects[mode] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sideFeedLinger, execute: work)
    }
}
