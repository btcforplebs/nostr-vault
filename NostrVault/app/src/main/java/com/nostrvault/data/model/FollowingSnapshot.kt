package com.nostrvault.data.model

import kotlinx.serialization.Serializable

/**
 * A snapshot of the user's following list at a point in time.
 * Used for following backup/restore functionality.
 */
@Serializable
data class FollowingSnapshot(
    val id: String,
    val capturedAt: Long,
    val pubkeys: List<String>,
    val pTags: List<List<String>>,
    val contactListContent: String,
    /**
     * created_at (unix seconds) of the kind-3 event this snapshot represents.
     * Null for legacy snapshots written before this field existed. Used to refuse
     * older relay copies that would clobber a newer local edit.
     */
    val contactListCreatedAt: Long? = null,
) {
    val followCount: Int get() = pubkeys.size
}

@Serializable
data class FollowingSnapshotStore(
    val snapshots: List<FollowingSnapshot>,
) {
    companion object {
        const val MAX_SNAPSHOTS = 50
    }
}

/**
 * A historical kind-3 contact list event discovered by scanning relays.
 * Used by Following Backup recovery to restore an older following list.
 */
data class Kind3Event(
    val id: String,
    val createdAt: Long, // unix seconds
    val pubkeys: List<String>,
    val pTags: List<List<String>>,
    val content: String,
) {
    val followCount: Int get() = pubkeys.size
}
