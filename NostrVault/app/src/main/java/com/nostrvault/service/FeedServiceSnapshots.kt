package com.nostrvault.service

import android.util.Log
import coil.request.CachePolicy
import coil.request.ImageRequest
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.io.File
import kotlin.concurrent.withLock
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.Companion.SNAPSHOT_MAX_AGE_MS
import com.nostrvault.service.FeedService.Companion.AVATAR_PREWARM_COUNT

    internal suspend fun FeedService.restoreFromDiskIfAvailable(): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val key = currentSnapshotKey()
                val dir = configStore.config.value.appSupportDir ?: return@withContext false
                val file = File(dir, "feed_snapshot_$key.json")
                if (!file.exists()) return@withContext false

                val content = file.readText()
                val snapshot = json.decodeFromString(DiskFeedSnapshot.serializer(), content)

                // Check age
                if (System.currentTimeMillis() - snapshot.savedAt > SNAPSHOT_MAX_AGE_MS) {
                    file.delete()
                    return@withContext false
                }

                // Populate seenIds from restored notes to prevent duplicates on top-up
                seenIdsLock.withLock {
                    for (note in snapshot.notes) {
                        seenIds.add(note.id)
                    }
                }

                withContext(Dispatchers.Main.immediate) {
                    // distinctBy: a snapshot written while _notes briefly held a
                    // duplicate id would otherwise crash-loop every launch
                    // (LazyColumn duplicate key on first render).
                    // A snapshot saved before a delete still holds the post.
                    _notes.value = withoutDeletedNotes(snapshot.notes.distinctBy { it.id })
                    _followedPubkeys.value = snapshot.followedPubkeys
                    _noteStats.value = snapshot.noteStats
                    contactListContent = snapshot.contactListContent
                    _likedEventIds.value = snapshot.likedEventIds
                    _zappedEventIds.value = snapshot.zappedEventIds
                    _hasAttemptedContactLoad.value = true

                    // Restore scroll position so the feed opens where the user left off
                    if (snapshot.scrollIndex > 0) {
                        _restoredScrollPosition.value = ScrollPosition(
                            snapshot.scrollIndex,
                            snapshot.scrollOffset,
                        )
                    }

                    // Warm avatar memory cache before UI renders the list
                    prewarmAvatarCache(snapshot.notes)

                    recomputeFilteredNotes()
                }

                true
            } catch (e: Exception) {
                Log.w(TAG, "Snapshot restore failed: ${e.message}")
                false
            }
        }
    }

    /**
     * Pre-warm Coil's memory cache for avatar images of the first visible notes.
     * Loads from disk cache → memory so avatars render instantly without the
     * gradient-fallback flash on resume.
     */
    internal fun FeedService.prewarmAvatarCache(notes: List<FeedNote>) {
        val profiles = nostrService.profiles.value
        val subset = notes.take(AVATAR_PREWARM_COUNT)
        val urls = subset
            .flatMap { note ->
                listOfNotNull(
                    profiles[note.repostedBy ?: note.pubkey]?.pictureURL,
                    note.replyToPubkey?.let { profiles[it]?.pictureURL },
                )
            }
            .distinct()
            .filter { url ->
                val key = coil.memory.MemoryCache.Key(url)
                imageLoader.memoryCache?.get(key) == null
            }

        if (urls.isEmpty()) return
        if (BuildConfig.DEBUG) Log.d(TAG, "Pre-warming ${urls.size} avatar(s) into memory cache")

        scope.launch(Dispatchers.IO) {
            coroutineScope {
                urls.map { url ->
                    async {
                        try {
                            val request = ImageRequest.Builder(appContext)
                                .data(url)
                                .size(128)
                                .memoryCachePolicy(CachePolicy.ENABLED)
                                .diskCachePolicy(CachePolicy.ENABLED)
                                .allowHardware(true)
                                .build()
                            imageLoader.execute(request)
                        } catch (_: Exception) { /* best-effort */ }
                    }
                }.awaitAll()
            }
        }
    }

    internal fun FeedService.topUpFromRelays() {
        _isSyncing.value = true
        _connectionStatus.value = "Syncing..."

        // Subscribe to relays immediately (background sync)
        subscribeToAllRelays()

        // Load contacts in background (doesn't block visible feed)
        scope.launch { loadContactList() }
    }

    /**
     * The previous account's follows, forgotten on an account switch only: a
     * new account whose load finds no list (but is confirmed) would otherwise
     * publish them as its own. Not part of [clearInMemoryFeedState], which
     * Settings > Reload Feed also runs on the same account, where the list in
     * memory is the one a follow tap must publish over.
     */
    internal fun FeedService.forgetFollowListForAccountSwitch() {
        _followedPubkeys.value = emptyList()
        contactListContent = ""
        contactListTags = emptyList()
    }

    internal fun FeedService.clearInMemoryFeedState() {
        // A merge still running would publish the old account's notes and
        // counts into the cleared feed.
        cancelMergeWorker()
        // A feed switch between the pubkey flipping and this reset filed
        // the old account's notes under the new one's key.
        modeCaches.clear()
        _notes.value = emptyList()
        _pendingNotes.value = emptyList()
        _noteStats.value = emptyMap()
        _newNoteCount.value = 0
        resetFeedThreadReplies()
        seenIdsLock.withLock { seenIds.clear() }
        rawEventCache.clear()
        // A new account means new relays: what this one couldn't find, the
        // next might.
        unavailableSince.clear()
        _unavailableNoteIds.value = emptySet()
        relayListRequested.clear()
        contactListConfirmed = false
        pendingFollowActions.clear()
        notificationManager.clearPendingFollows()
        recomputeFilteredNotes()
    }
