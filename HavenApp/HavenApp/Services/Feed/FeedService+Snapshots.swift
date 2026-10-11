import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Stable in-memory cache key for the active account. Uses the configured
    /// `activeAccountNpub`, falling back to "owner" when the owner account is
    /// active so we never key on an empty string.
    func currentSnapshotKey() -> String {
        let npub = ConfigService.shared.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return npub.isEmpty ? "owner" : npub
    }

    /// Capture the current published feed state into `accountSnapshots[key]`.
    /// Bounded to ~200 notes so re-switching is cheap; full backfill comes
    /// from the top-up subscription that runs immediately after.
    func captureSnapshot(forKey key: String) {
        // Leaving an account before its feed loaded has nothing worth keeping,
        // and writing it would replace that account's last good snapshot — in
        // memory and on disk — with an empty one that later restores as a
        // blank feed.
        guard !key.isEmpty, !notes.isEmpty else { return }
        let cappedNotes = Array(notes.prefix(200))
        let snap = AccountFeedSnapshot(
            notes: cappedNotes,
            parentNotesCache: parentNotesCache,
            followedPubkeys: followedPubkeys,
            extendedNetworkPubkeys: extendedNetworkPubkeys,
            seenIds: seenIds,
            noteStats: noteStats,
            likedEventIds: likedEventIds,
            zappedEventIds: zappedEventIds,
            contactListContent: contactListContent,
            contactListPTags: contactListPTags,
            lastFetchedContactCount: lastFetchedContactCount,
            hasAttemptedContactLoad: hasAttemptedContactLoad,
            capturedAt: Date(),
            lastEventTimestamp: lastEventTimestamp
        )
        accountSnapshots[key] = snap
        saveDiskSnapshot(forKey: key)
    }

    /// Restore a previously captured snapshot into published state. Returns
    /// true if a snapshot existed and was restored.
    @discardableResult
    func restoreSnapshot(forKey key: String) -> Bool {
        guard let snap = accountSnapshots[key] else { return false }
        notes = snap.notes
        parentNotesCache = snap.parentNotesCache
        followedPubkeys = snap.followedPubkeys
        extendedNetworkPubkeys = snap.extendedNetworkPubkeys
        seenIds = snap.seenIds
        noteStats = snap.noteStats
        likedEventIds = snap.likedEventIds
        zappedEventIds = snap.zappedEventIds
        // Which emoji went with each like lives only in the account's file.
        let saved = EngagementTracker.loadInteractionState(forKey: key)
        myReactions = saved.myReactions
        retractedReactionIds = saved.retractedReactionIds
        contactListContent = snap.contactListContent
        contactListPTags = snap.contactListPTags
        lastFetchedContactCount = snap.lastFetchedContactCount
        hasAttemptedContactLoad = snap.hasAttemptedContactLoad
        lastEventTimestamp = snap.lastEventTimestamp
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        recomputeFilteredNotes()
        return true
    }

    /// Reset just the in-memory published feed state (does not touch snapshots).
    /// Used before a cold load when no snapshot exists for the new account.
    func clearInMemoryFeedState() {
        followedPubkeys.removeAll()
        extendedNetworkPubkeys.removeAll()
        notes.removeAll()
        parentNotesCache.removeAll()
        parentNotesCacheTrimAt = 500
        processingQueue.async { [bgAccumulator] in bgAccumulator.resetParentFetchClaims() }
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        fetchingNoteIds.removeAll()
        fetchingNoteTimestamps.removeAll()
        noteFetchQueue.removeAll()
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        noteFetchPasses.removeAll()
        unavailableNoteIds.removeAll()
        noteStats.removeAll()
        popularNoteScores.removeAll()
        resetFeedThreadReplies()
        isLoadingPopular = false
        likedEventIds.removeAll()
        myReactions.removeAll()
        retractedReactionIds.removeAll()
        zappedEventIds.removeAll()
        contactListContent = ""
        contactListPTags.removeAll()
        lastFetchedContactCount = 0
        ownContactListCreatedAt = 0
        ownContactListAccountKey = ""
        hasAttemptedContactLoad = false
        contactListConfirmed = false
        pendingFollowActions.removeAll()
        FollowNotificationManager.shared.clearPending()
        lastEventTimestamp = 0
        recomputeFilteredNotes()
    }

    // MARK: - Disk Snapshot Persistence

    private nonisolated static func diskSnapshotURL(forKey key: String) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let safeKey = key.isEmpty ? "owner" : key.replacingOccurrences(of: "/", with: "_")
        return havenDir.appendingPathComponent("feed_snapshot_\(safeKey).json")
    }

    private func saveDiskSnapshot(forKey key: String) {
        let disk = DiskFeedSnapshot(
            notes: Array(notes.prefix(200)),
            followedPubkeys: followedPubkeys,
            extendedNetworkPubkeys: extendedNetworkPubkeys,
            noteStats: noteStats,
            contactListContent: contactListContent,
            contactListPTags: contactListPTags,
            lastFetchedContactCount: lastFetchedContactCount,
            capturedAt: Date(),
            lastEventTimestamp: lastEventTimestamp,
            ownContactListCreatedAt: ownContactListCreatedAt
        )
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(disk) {
                try? data.write(to: Self.diskSnapshotURL(forKey: key))
            }
        }
    }

    private func loadDiskSnapshot(forKey key: String) -> DiskFeedSnapshot? {
        let url = Self.diskSnapshotURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(DiskFeedSnapshot.self, from: data) else {
            return nil
        }
        // Expire stale snapshots.
        if snap.capturedAt.timeIntervalSinceNow < -DiskFeedSnapshot.maxAge { return nil }
        return snap
    }

    func diskSnapshotExists(forKey key: String) -> Bool {
        let url = Self.diskSnapshotURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Quick check: if file exists and isn't expired, we have a snapshot.
        // Don't decode the entire snapshot here — just check modification date.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return modDate.timeIntervalSinceNow >= -DiskFeedSnapshot.maxAge
    }

    /// Apply an on-disk snapshot for `key` into the published feed state.
    /// Mirrors the in-memory `restoreSnapshot` but sources from disk. Returns
    /// true when a (non-stale) snapshot existed and was applied. Does NOT start
    /// any relay traffic — the caller decides whether to top up or cold-load.
    @discardableResult
    func applyDiskSnapshot(forKey key: String) -> Bool {
        // Builds before captureSnapshot refused an empty feed wrote empty
        // snapshots to disk; applied, they show a blank feed with no loading
        // state. Treat one as missing so the caller loads the account instead.
        guard let diskSnap = loadDiskSnapshot(forKey: key), !diskSnap.notes.isEmpty else { return false }
        notes = diskSnap.notes
        followedPubkeys = diskSnap.followedPubkeys
        extendedNetworkPubkeys = diskSnap.extendedNetworkPubkeys
        if !diskSnap.extendedNetworkPubkeys.isEmpty {
            extendedNetworkComputedAt = diskSnap.capturedAt
        }
        noteStats = diskSnap.noteStats
        contactListContent = diskSnap.contactListContent
        contactListPTags = diskSnap.contactListPTags
        lastFetchedContactCount = diskSnap.lastFetchedContactCount
        ownContactListCreatedAt = diskSnap.ownContactListCreatedAt ?? 0
        ownContactListAccountKey = key
        seenIds = Set(diskSnap.notes.map { $0.id })
        lastEventTimestamp = diskSnap.lastEventTimestamp
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        loadInteractionState(forKey: key)
        recomputeFilteredNotes()
        return true
    }

    /// Cold-launch restore. When the feed is empty (fresh process) and a
    /// non-stale disk snapshot exists for the active account, restore it so the
    /// user sees their previous feed instantly. Returns true when restored — the
    /// caller should then run `topUpFromRelays()` to stream newer notes on top
    /// without a full reload. Returns false on first-ever launch (no snapshot),
    /// where the caller should fall back to `refresh()`.
    @discardableResult
    func restoreFromDiskIfAvailable() -> Bool {
        guard notes.isEmpty else { return false }
        let key = currentSnapshotKey()
        loadedSnapshotNpub = key
        return applyDiskSnapshot(forKey: key)
    }

    /// Restore the cached feed at launch, before the relay is ready.
    ///
    /// Everything here is a local read — a disk snapshot, or the follow set from
    /// the following backup. None of it needs a relay, and holding it back until
    /// `isReadyForConnections` (three seconds after the relay reports running) is
    /// what made every launch flash an empty Following feed with a Refresh
    /// button. Subscribing is still the readiness sink's job.
    func prewarmFromCache() {
        guard !didRestoreCachedFeed, !didStartInitialLoad, !isPaused, feedMode != .popular else { return }

        if restoreFromDiskIfAvailable() {
            didRestoreCachedFeed = true
            return
        }

        // No cached notes, but a known follow set still turns the launch screen
        // from an accusation into a feed that is merely still filling.
        guard followedPubkeys.isEmpty,
              let backup = FollowingBackupService.shared.snapshots.last,
              !backup.pubkeys.isEmpty else { return }
        contactListPTags = backup.pTags
        followedPubkeys = backup.pubkeys
        contactListContent = backup.contactListContent
        lastFetchedContactCount = backup.pubkeys.count
    }

    /// Persist the current feed to disk so the next cold launch can restore it
    /// instantly (see `restoreFromDiskIfAvailable`). Call from app background /
    /// terminate hooks while notes are still in memory. No-op when the feed is
    /// empty. The actual encode + write runs off the main thread.
    func persistCurrentSnapshot() {
        guard !notes.isEmpty else { return }
        let key = loadedSnapshotNpub.isEmpty ? currentSnapshotKey() : loadedSnapshotNpub
        saveDiskSnapshot(forKey: key)
    }
}
