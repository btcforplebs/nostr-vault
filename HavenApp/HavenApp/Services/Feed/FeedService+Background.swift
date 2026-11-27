import Foundation

extension FeedService {
    /// Lets go of the feed's notes when the Mac runs in background mode and
    /// its window closes (BackgroundMode). The feed is saved to disk first and
    /// its relay clients are disconnected; the follow list, likes and pending
    /// follow actions stay in memory, since they are small and still owed to
    /// the relay. `returnFromBackground` brings it back.
    func releaseForBackground() {
        persistCurrentSnapshot()
        // Cleared first so pauseFeed tears down whatever is open even when the
        // feed is already marked paused (an account switch subscribes without
        // looking at the flag).
        isPaused = false
        pauseFeed()
        notes.removeAll()
        noteIndex.removeAll()
        parentNotesCache.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        noteStats.removeAll()
        popularNoteScores.removeAll()
        noteLanguageCache.removeAll()
        rawEventCache.removeAll()
        rawEventCacheOrder.removeAll()
        didRestoreCachedFeed = false
        didStartInitialLoad = false
        recomputeFilteredNotes()
    }

    /// The window is open again: load the feed the way a cold launch does,
    /// from the snapshot saved on release, then a top-up from the relays.
    ///
    /// Not `resumeFeed`: that only re-subscribes, and FeedView's appear
    /// handler takes the resume branch whenever the feed is paused, so the
    /// saved notes would never come back. Unpaused here, before the window's
    /// views ask; once the relay is ready this starts the load itself,
    /// otherwise the readiness observer does when it is.
    func returnFromBackground() {
        isPaused = false
        if RelayProcessManager.shared.isReadyForConnections, !didStartInitialLoad {
            startInitialLoad()
        }
    }

    /// An account switched from the menu bar panel while the Mac runs in
    /// background mode: `handleAccountSwitch` loads that account's notes and
    /// subscribes to its relays whether or not the feed is paused, so let go
    /// of them again (Tron, #2326). The window brings them back when it opens.
    func afterAccountSwitchInBackground() {
        #if os(macOS)
        guard BackgroundMode.shared.isReleased else { return }
        releaseForBackground()
        #endif
    }
}
