import Foundation

extension FeedService {
    /// Lets go of the feed's notes when the Mac runs in background mode and
    /// its window closes (BackgroundMode). The feed is saved to disk first and
    /// its relay clients are disconnected; the follow list, likes and pending
    /// follow actions stay in memory, since they are small and still owed to
    /// the relay. Opening the window again restores the saved feed from disk
    /// (`startInitialLoad` sees an empty feed) and tops it up.
    func releaseForBackground() {
        persistCurrentSnapshot()
        pauseFeed()
        notes.removeAll()
        noteIndex.removeAll()
        parentNotesCache.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        searchResults.removeAll()
        noteStats.removeAll()
        popularNoteScores.removeAll()
        noteLanguageCache.removeAll()
        rawEventCache.removeAll()
        rawEventCacheOrder.removeAll()
        didRestoreCachedFeed = false
        didStartInitialLoad = false
        recomputeFilteredNotes()
    }
}
