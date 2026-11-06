package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.PopularNoteResult
import com.nostrvault.data.model.isLocalDvm
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService.Companion.TAG
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

// ══════════════════════════════════════════════════════════════════
// Feeds the relay's local DVM computes: Popular, Catch Up, Underrated
// (haven-go dvm.go, feed_catchup.go, feed_underrated.go). iOS
// FeedService+LocalDvmFeeds.
// ══════════════════════════════════════════════════════════════════

/** The pure parts, unit-tested. */
internal object LocalDvmFeeds {
    private val HEX64 = Regex("^[0-9a-f]{64}$")

    /**
     * The follow list Catch Up is computed for, as the JSON array the relay
     * reads: lowercased hex pubkeys, anything else dropped, no duplicates.
     */
    fun followsJson(follows: Collection<String>): String =
        JsonArray(
            follows.map { it.trim().lowercase() }.filter { HEX64.matches(it) }.distinct().map { JsonPrimitive(it) },
        ).toString()

    fun computingStatus(mode: FeedMode): String = when (mode) {
        FeedMode.CATCH_UP -> "Catching up..."
        FeedMode.UNDERRATED -> "Finding underrated notes..."
        else -> "Computing popular..."
    }

    /**
     * An empty answer. Popular and Underrated are withheld while the trust
     * graph is built, so "nothing found" would be wrong then (iOS
     * curatedGraphPendingStatus); Catch Up reads only your follows.
     */
    fun emptyStatus(mode: FeedMode, graphReady: Boolean, followsNobody: Boolean): String = when {
        mode == FeedMode.CATCH_UP && followsNobody -> "Follow people to catch up with them"
        mode == FeedMode.CATCH_UP -> "Nobody you follow posted lately"
        graphReady -> if (mode == FeedMode.UNDERRATED) "No underrated notes" else "No popular notes"
        followsNobody -> "Follow people to build your web of trust"
        else -> "Building your web of trust…"
    }
}

/**
 * Computes [mode] on the relay. One computation per feed at a time: a second
 * pull or tab tap would race the first, and whichever landed last would win
 * (iOS loadPopularFeed). Each feed has its own guard, so leaving Popular
 * mid-compute for Catch Up still computes Catch Up.
 */
internal fun FeedService.loadLocalDvmFeed(mode: FeedMode) {
    if (!mode.isLocalDvm || !localDvmLoading.add(mode)) return
    if (mode == FeedMode.POPULAR) _isLoadingPopular.value = true
    _isLoadingFeed.value = true
    _connectionStatus.value = LocalDvmFeeds.computingStatus(mode)
    resetFeedThreadReplies()
    val account = nostrService.activeHexPubkey
    // Read on the calling thread: the active account's follows now.
    val follows = if (mode == FeedMode.CATCH_UP) LocalDvmFeeds.followsJson(_followedPubkeys.value) else ""

    scope.launch(Dispatchers.Default) {
        val loaded: Pair<List<FeedNote>, Map<String, Double>>? = try {
            val resultJson = when (mode) {
                FeedMode.CATCH_UP -> HavenBridge.computeCatchUpNotes(follows)
                FeedMode.UNDERRATED -> HavenBridge.computeUnderratedNotes()
                else -> HavenBridge.computePopularNotes()
            }
            if (resultJson.isNullOrEmpty()) {
                emptyList<FeedNote>() to emptyMap()
            } else {
                val results = json.decodeFromString<List<PopularNoteResult>>(resultJson)
                val notes = results.mapNotNull { r ->
                    FeedNote.fromEvent(r.id, r.pubkey, r.content, r.tags, r.createdAt, r.kind)
                        .takeIf { !it.isNoiseOrSpam() }
                }
                notes to results.associate { it.id to it.score }
            }
        } catch (e: Exception) {
            Log.w(TAG, "${mode.displayName} feed failed: ${e.message}")
            null
        }

        withContext(Dispatchers.Main.immediate) {
            localDvmLoading.remove(mode)
            if (mode == FeedMode.POPULAR) _isLoadingPopular.value = false
            // A result that lands after you left this feed, or changed
            // account, belongs to no feed on screen: writing it would
            // replace the feed you are looking at.
            if (_feedMode.value != mode || nostrService.activeHexPubkey != account) {
                // A feed with no note subscription never clears the
                // spinner itself; one that subscribes owns it now.
                if (!FeedModeCaches.usesNotePipeline(_feedMode.value)) _isLoadingFeed.value = false
                return@withContext
            }
            _isLoadingFeed.value = false
            if (loaded == null) {
                _connectionStatus.value = "${mode.displayName} feed error"
                return@withContext
            }
            val (notes, scores) = loaded
            _notes.value = notes
            _popularNoteScores.value = scores
            _connectionStatus.value = if (notes.isNotEmpty()) {
                mode.displayName
            } else {
                LocalDvmFeeds.emptyStatus(mode, graphReady = _wotPubkeys.value.isNotEmpty(), followsNobody = _followedPubkeys.value.isEmpty())
            }
            recomputeFilteredNotes()
        }
    }
}
