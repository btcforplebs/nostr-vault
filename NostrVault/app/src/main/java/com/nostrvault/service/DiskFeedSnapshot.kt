package com.nostrvault.service

import com.nostrvault.data.model.*

// ── Disk snapshot ─────────────────────────────────────────────────

@kotlinx.serialization.Serializable
data class DiskFeedSnapshot(
    val notes: List<FeedNote>,
    val followedPubkeys: List<String>,
    val noteStats: Map<String, NoteStats>,
    val contactListContent: String,
    val likedEventIds: Set<String>,
    val zappedEventIds: Map<String, Int>,
    val savedAt: Long,
    val lastEventTimestamp: Long = 0L,
    val scrollIndex: Int = 0,
    val scrollOffset: Int = 0,
)
