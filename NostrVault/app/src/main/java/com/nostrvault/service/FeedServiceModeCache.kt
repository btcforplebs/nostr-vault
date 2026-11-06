package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.isLocalDvm
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NoteStats
import kotlin.concurrent.withLock

/**
 * One feed as it was when you switched away. iOS: `FeedService.ModeFeedCache`.
 */
internal data class ModeFeedCache(
    val notes: List<FeedNote>,
    val noteStats: Map<String, NoteStats>,
    val popularNoteScores: Map<String, Double>,
    val capturedAtMs: Long,
    /** [currentFeedNotesKey] when the feed had finished loading, else null: the REQ resumes only from a full list. */
    val feedKey: String? = null,
    /** The relays that answered the load [feedKey] stands for; only they resume. */
    val feedRelays: Set<String> = emptySet(),
    /** Read back from disk after a relaunch (FeedModeCacheDisk.kt): kept for [FeedModeCaches.DISK_MAX_AGE_MS]. */
    val fromDisk: Boolean = false,
)

/**
 * The last notes of each feed you switched away from, so switching back shows
 * them at once instead of starting over. Keyed by account + feed (+ the
 * Following / Global scope of Media, Articles, Recipes and Polls), so nothing
 * crosses accounts. In memory only, and Main-confined like [FeedService.switchMode].
 * iOS: `FeedService+ModeCache.swift`.
 */
internal class FeedModeCaches(private val now: () -> Long = System::currentTimeMillis) {
    private val caches = HashMap<String, ModeFeedCache>()

    fun put(
        key: String,
        notes: List<FeedNote>,
        noteStats: Map<String, NoteStats>,
        scores: Map<String, Double>,
        feedKey: String? = null,
        feedRelays: Set<String> = emptySet(),
    ): ModeFeedCache? {
        if (notes.isEmpty()) return null
        return ModeFeedCache(
            notes, noteStats, scores, now(), feedKey,
            feedRelays = if (feedKey != null) feedRelays else emptySet(),
        ).also { caches[key] = it }
    }

    /** A feed saved before the relaunch; one filed since then is newer and stays. */
    fun putSaved(key: String, cache: ModeFeedCache) {
        if (cache.notes.isEmpty() || key in caches) return
        caches[key] = cache.copy(fromDisk = true)
    }

    /** The cache and its age in ms, or null when there is none fresh enough; a stale one is dropped. */
    fun take(key: String): Pair<ModeFeedCache, Long>? {
        val cache = caches[key] ?: return null
        val age = now() - cache.capturedAtMs
        if (age >= (if (cache.fromDisk) DISK_MAX_AGE_MS else MAX_AGE_MS) || cache.notes.isEmpty()) {
            caches.remove(key)
            return null
        }
        return cache to age
    }

    /** Drops every account's feeds: on an account switch, nothing filed in the switch window survives. */
    fun clear() = caches.clear()

    companion object {
        /**
         * The notes on screen belong to [active]: the account they were
         * cleared for, or (before any switch) whoever is active, if anyone.
         */
        fun ownsNotes(notesAccount: String?, active: String): Boolean =
            active.isNotEmpty() && (notesAccount == null || notesAccount == active)

        /** Older than this, a cached feed is dropped and the feed loads as before. */
        const val MAX_AGE_MS = 15 * 60 * 1000L

        /** A feed saved to disk is shown after a relaunch for this long, as the launch snapshot is. */
        const val DISK_MAX_AGE_MS = FeedService.SNAPSHOT_MAX_AGE_MS

        /** Popular is computed, not streamed; within this it is shown as cached, with no recompute. */
        const val POPULAR_FRESH_MS = 5 * 60 * 1000L

        /** Raw notes kept on top of what was on screen. */
        const val RAW_KEPT = 200

        /** Feeds whose notes come through FeedService's own note list. */
        fun usesNotePipeline(mode: FeedMode): Boolean = when (mode) {
            FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL, FeedMode.POPULAR,
            FeedMode.CATCH_UP, FeedMode.UNDERRATED, FeedMode.MEDIA, FeedMode.ARTICLES, FeedMode.RECIPES, FeedMode.POLLS -> true
            else -> false
        }

        /**
         * Everything that was on screen, the notes waiting behind the "new
         * posts" pill, and the newest raw notes, newest first. A filtered feed
         * (Global keeps only trusted authors) can show a handful out of
         * hundreds, and the newest raw notes alone would drop what was visible.
         */
        fun notesToKeep(shown: List<FeedNote>, pending: List<FeedNote>, raw: List<FeedNote>): List<FeedNote> =
            (shown + pending + raw.take(RAW_KEPT))
                .distinctBy { it.id }
                .sortedWith(compareByDescending<FeedNote> { it.createdAt }.thenByDescending { it.id })
    }
}

/** Account + feed (+ its scope), as the cache is keyed. */
internal fun FeedService.modeCacheKey(mode: FeedMode): String {
    var key = "${nostrService.activeHexPubkey}|${mode.name}"
    when (mode) {
        FeedMode.MEDIA -> key += "|${_mediaFeedMode.value}"
        FeedMode.ARTICLES -> key += "|${_articlesFeedMode.value}"
        FeedMode.RECIPES -> key += "|${_recipesFeedMode.value}"
        FeedMode.POLLS -> key += "|${_pollsFeedMode.value}"
        else -> Unit
    }
    return key
}

/** Keeps what [mode] showed, for a quick switch back. Call before the mode changes. */
internal fun FeedService.captureModeCache(mode: FeedMode) {
    if (!FeedModeCaches.usesNotePipeline(mode) || _notes.value.isEmpty()) return
    // Between the account flipping and clearInMemoryFeedState, the list is
    // still the previous account's: never file it (or save it) under this one.
    if (!FeedModeCaches.ownsNotes(notesAccount, nostrService.activeHexPubkey)) return
    if (notesAccount == null) notesAccount = nostrService.activeHexPubkey
    // Until its result lands, a local DVM feed is showing the previous feed's notes.
    if (mode.isLocalDvm && (mode in localDvmLoading || _popularNoteScores.value.isEmpty())) return
    val kept = FeedModeCaches.notesToKeep(_filteredNotes.value, _pendingNotes.value, _notes.value)
    val ids = kept.mapTo(HashSet()) { it.id }
    val key = modeCacheKey(mode)
    val cache = modeCaches.put(
        key = key,
        notes = kept,
        noteStats = _noteStats.value.filterKeys { it in ids },
        scores = _popularNoteScores.value,
        // Called before the mode changes, so this is still [mode]'s key.
        feedKey = feedNotesKey?.takeIf { it == currentFeedNotesKey() },
        feedRelays = feedNotesRelays.toSet(),
    ) ?: return
    if (mode in FeedModeCacheDisk.MODES) saveModeCacheToDisk(key, cache)
}

/**
 * Puts [mode]'s cached feed back on screen. Returns its age in ms, or null
 * when there was nothing fresh enough and the feed loads as it always has.
 */
internal fun FeedService.restoreModeCache(mode: FeedMode): Long? {
    if (!FeedModeCaches.usesNotePipeline(mode)) return null
    val (cache, age) = modeCaches.take(modeCacheKey(mode)) ?: run {
        // The list left on screen is the previous feed's.
        forgetFeedNotesKey()
        return null
    }
    feedNotesKey = cache.feedKey
    feedNotesRelays.clear()
    if (cache.feedKey != null) feedNotesRelays.addAll(cache.feedRelays)
    // A merge still running would publish the old list over this one.
    cancelMergeWorker()
    // A cache saved before a delete still holds the post.
    _notes.value = withoutDeletedNotes(cache.notes)
    _noteStats.value = cache.noteStats
    _popularNoteScores.value = cache.popularNoteScores
    // Seen = exactly what was kept: anything dropped can come back from relays
    // instead of being refused as already seen.
    seenIdsLock.withLock {
        seenIds.clear()
        cache.notes.mapTo(seenIds) { it.id }
    }
    return age
}

/**
 * Popular on a switch: a result under five minutes old is shown as it was;
 * anything older (or none) is computed again.
 */
internal fun FeedService.showCachedLocalDvmOrLoad(mode: FeedMode, cachedAgeMs: Long?) {
    if (cachedAgeMs == null || cachedAgeMs >= FeedModeCaches.POPULAR_FRESH_MS) return loadLocalDvmFeed(mode)
    if (mode == FeedMode.POPULAR) _isLoadingPopular.value = false
    _connectionStatus.value = mode.displayName
}
