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
        let cache = ModeFeedCache(
            notes: cached,
            parentNotesCache: parentNotesCache,
            noteStats: noteStats,
            popularNoteScores: popularNoteScores,
            capturedAt: Date()
        )
        modeCaches[modeCacheKey(mode)] = cache
        saveDiskModeCache(cache, mode: mode)
    }

    /// A Popular ranking that finished after you left Popular: filed as
    /// Popular's cache (memory and disk) so the next visit shows it at once.
    func storePopularResult(_ ranked: [FeedNote], scores: [String: Double]) {
        guard !ranked.isEmpty else { return }
        let cache = ModeFeedCache(notes: ranked, parentNotesCache: [:], noteStats: [:],
                                  popularNoteScores: scores, capturedAt: Date())
        modeCaches[modeCacheKey(.popular)] = cache
        saveDiskModeCache(cache, mode: .popular)
    }

    /// Puts a cached feed back on screen. Returns its age, or nil if there was
    /// nothing fresh enough to show.
    func restoreModeCache(for mode: FeedMode) -> TimeInterval? {
        let key = modeCacheKey(mode)
        // Discover and Popular are also kept on disk, so they are instant on
        // a cold launch too (FeedSpeedPolicy.persistsModeCache).
        if modeCaches[key] == nil, let fromDisk = loadDiskModeCache(mode: mode) {
            modeCaches[key] = fromDisk
        }
        guard let cache = modeCaches[key] else { return nil }
        let age = Date().timeIntervalSince(cache.capturedAt)
        let maxAge = FeedSpeedPolicy.modeCacheMaxAge(persisted: FeedSpeedPolicy.persistsModeCache(mode.rawValue))
        guard age < maxAge, !cache.notes.isEmpty, !isGlobalCacheOfStrangers(cache.notes) else {
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

    // MARK: - Disk (Discover and Popular)

    private struct DiskModeFeedCache: Codable {
        var notes: [FeedNote]
        var noteStats: [String: NoteStats]
        var popularNoteScores: [String: Double]
        var capturedAt: Date
    }

    private nonisolated static func diskModeCacheURL(key: String) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(FeedSpeedPolicy.diskModeCacheFileName(cacheKey: key))
    }

    /// Writes Discover's or Popular's cache for this account, off the main
    /// thread. Other feeds stay memory-only.
    private func saveDiskModeCache(_ cache: ModeFeedCache, mode: FeedMode) {
        guard FeedSpeedPolicy.persistsModeCache(mode.rawValue), !cache.notes.isEmpty,
              let url = Self.diskModeCacheURL(key: modeCacheKey(mode)) else { return }
        let disk = DiskModeFeedCache(notes: Array(cache.notes.prefix(200)), noteStats: cache.noteStats,
                                     popularNoteScores: cache.popularNoteScores, capturedAt: cache.capturedAt)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(disk) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func loadDiskModeCache(mode: FeedMode) -> ModeFeedCache? {
        guard FeedSpeedPolicy.persistsModeCache(mode.rawValue),
              let url = Self.diskModeCacheURL(key: modeCacheKey(mode)),
              let data = try? Data(contentsOf: url),
              let disk = try? JSONDecoder().decode(DiskModeFeedCache.self, from: data),
              !disk.notes.isEmpty,
              Date().timeIntervalSince(disk.capturedAt) < FeedSpeedPolicy.modeCacheMaxAge(persisted: true) else { return nil }
        return ModeFeedCache(notes: disk.notes, parentNotesCache: [:], noteStats: disk.noteStats,
                             popularNoteScores: disk.popularNoteScores, capturedAt: disk.capturedAt)
    }

    /// A Global cache in which your web names nobody, saved while the web was
    /// still empty. Resuming from its newest stranger's note never asked for
    /// your people's older notes, so Global stayed blank on every return.
    private func isGlobalCacheOfStrangers(_ cached: [FeedNote]) -> Bool {
        guard isGlobalLikeMode, let trust = globalTrustSet() else { return false }
        return !cached.contains { trust.contains($0.pubkey) }
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
