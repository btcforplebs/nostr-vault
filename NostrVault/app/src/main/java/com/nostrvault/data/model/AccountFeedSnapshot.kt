package com.nostrvault.data.model

import java.util.Date

// ---------------------------------------------------------------------------
// Account snapshots (for instant account switching)
// ---------------------------------------------------------------------------

data class AccountFeedSnapshot(
    var notes: List<FeedNote> = emptyList(),
    var parentNotesCache: Map<String, FeedNote> = emptyMap(),
    var followedPubkeys: List<String> = emptyList(),
    var extendedNetworkPubkeys: List<String> = emptyList(),
    var seenIds: MutableSet<String> = mutableSetOf(),
    var noteStats: Map<String, NoteStats> = emptyMap(),
    var likedEventIds: MutableSet<String> = mutableSetOf(),
    var zappedEventIds: MutableMap<String, Int> = mutableMapOf(),
    var contactListContent: String = "",
    var contactListPTags: List<List<String>> = emptyList(),
    var lastFetchedContactCount: Int = 0,
    var hasAttemptedContactLoad: Boolean = false,
    var capturedAt: Date = Date(),
    var lastEventTimestamp: Long = 0L,
)
