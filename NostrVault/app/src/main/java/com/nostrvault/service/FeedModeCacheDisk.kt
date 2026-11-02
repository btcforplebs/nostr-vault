package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NoteStats
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File
import com.nostrvault.service.FeedService.Companion.SNAPSHOT_MAX_NOTES
import com.nostrvault.service.FeedService.Companion.TAG

/** One feed's cache as written to disk. */
@Serializable
internal data class DiskModeCache(
    val notes: List<FeedNote>,
    val noteStats: Map<String, NoteStats> = emptyMap(),
    val popularNoteScores: Map<String, Double> = emptyMap(),
    val savedAt: Long,
    val feedKey: String? = null,
)

/**
 * Discover and Popular, saved across a relaunch. Both are slow to build
 * (Discover counts your follows' follows, Popular scores the relay's notes),
 * and the in-memory tab cache is gone after a relaunch, so they opened on a
 * spinner every time. Now the last ones show at once and are topped up or
 * re-ranked behind them. Following already has the launch snapshot
 * ([restoreFromDiskIfAvailable]); the other feeds stream quickly enough.
 *
 * One file per account and feed, in the app's support directory.
 */
internal object FeedModeCacheDisk {
    val MODES = setOf(FeedMode.DISCOVERY, FeedMode.POPULAR)

    /** [cacheKey] is [modeCacheKey]: account hex + feed name. */
    fun fileName(cacheKey: String): String =
        "feed_mode_" + cacheKey.replace(Regex("[^A-Za-z0-9]"), "_") + ".json"

    fun toDisk(cache: ModeFeedCache): DiskModeCache {
        val notes = cache.notes.take(SNAPSHOT_MAX_NOTES)
        val ids = notes.mapTo(HashSet()) { it.id }
        return DiskModeCache(
            notes = notes,
            noteStats = cache.noteStats.filterKeys { it in ids },
            popularNoteScores = cache.popularNoteScores.filterKeys { it in ids },
            savedAt = cache.capturedAtMs,
            feedKey = cache.feedKey,
        )
    }

    fun fromDisk(disk: DiskModeCache): ModeFeedCache = ModeFeedCache(
        notes = disk.notes.distinctBy { it.id },
        noteStats = disk.noteStats,
        popularNoteScores = disk.popularNoteScores,
        capturedAtMs = disk.savedAt,
        feedKey = disk.feedKey,
        fromDisk = true,
    )
}

internal fun FeedService.saveModeCacheToDisk(cacheKey: String, cache: ModeFeedCache) {
    val dir = configStore.config.value.appSupportDir ?: return
    scope.launch(Dispatchers.IO) {
        try {
            val text = json.encodeToString(DiskModeCache.serializer(), FeedModeCacheDisk.toDisk(cache))
            File(dir, FeedModeCacheDisk.fileName(cacheKey)).writeText(text)
        } catch (e: Exception) {
            Log.w(TAG, "Feed cache save failed: ${e.message}")
        }
    }
}

/**
 * Reads this account's saved Discover and Popular into the tab cache, once
 * per account, so a switch to either finds them. Returns once they are in.
 */
internal suspend fun FeedService.loadSavedModeCaches() {
    val account = nostrService.activeHexPubkey
    if (account.isEmpty() || savedModeCachesLoadedFor == account) return
    val dir = configStore.config.value.appSupportDir ?: return
    val keys = FeedModeCacheDisk.MODES.map { "$account|${it.name}" }
    val read = withContext(Dispatchers.IO) {
        keys.mapNotNull { key ->
            val file = File(dir, FeedModeCacheDisk.fileName(key))
            if (!file.exists()) return@mapNotNull null
            try {
                key to FeedModeCacheDisk.fromDisk(json.decodeFromString(DiskModeCache.serializer(), file.readText()))
            } catch (e: Exception) {
                Log.w(TAG, "Feed cache read failed: ${e.message}")
                file.delete()
                null
            }
        }
    }
    withContext(Dispatchers.Main.immediate) {
        // The account changed while reading: these belong to the old one.
        if (nostrService.activeHexPubkey != account) return@withContext
        read.forEach { (key, cache) -> modeCaches.putSaved(key, cache) }
        savedModeCachesLoadedFor = account
    }
}

/**
 * At launch, puts [mode]'s saved feed on screen when nothing is there yet.
 * Returns its age in ms, or null when there was none.
 */
internal suspend fun FeedService.restoreSavedModeCache(mode: FeedMode): Long? {
    if (mode !in FeedModeCacheDisk.MODES) return null
    loadSavedModeCaches()
    return withContext(Dispatchers.Main.immediate) {
        if (_feedMode.value != mode) return@withContext null
        restoreModeCache(mode)?.also { recomputeFilteredNotes() }
    }
}
