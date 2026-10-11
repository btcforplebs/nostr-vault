package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.io.File
import com.nostrvault.service.FeedService.Companion.SNAPSHOT_MAX_NOTES
import com.nostrvault.service.FeedService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Snapshots
    // ══════════════════════════════════════════════════════════════════

    fun FeedService.currentSnapshotKey(): String {
        return configStore.config.value.activeAccountNpub ?: "owner"
    }

    fun FeedService.persistCurrentSnapshot() {
        scope.launch(Dispatchers.IO) {
            val key = currentSnapshotKey()
            val newestTimestamp = _notes.value.firstOrNull()?.createdAt?.time?.div(1000) ?: 0L
            val snapshot = DiskFeedSnapshot(
                notes = _notes.value.take(SNAPSHOT_MAX_NOTES),
                followedPubkeys = _followedPubkeys.value,
                noteStats = _noteStats.value,
                contactListContent = contactListContent,
                likedEventIds = _likedEventIds.value,
                zappedEventIds = _zappedEventIds.value,
                savedAt = System.currentTimeMillis(),
                lastEventTimestamp = newestTimestamp,
                scrollIndex = _savedScrollIndex,
                scrollOffset = _savedScrollOffset,
            )

            try {
                val dir = configStore.config.value.appSupportDir ?: return@launch
                val file = File(dir, "feed_snapshot_$key.json")
                file.writeText(json.encodeToString(DiskFeedSnapshot.serializer(), snapshot))
            } catch (e: Exception) {
                Log.w(TAG, "Snapshot save failed: ${e.message}")
            }
        }
    }
