package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.PopularNoteResult
import com.nostrvault.data.model.isLocalDvm
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService.Companion.TAG
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
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
 * Why the relay's Underrated answer is empty (haven-go feed_underrated.go underratedEmptyReason):
 * ComputeUnderratedNotesC answers `{"reason": ...}` instead of an empty list. iOS UnderratedEmptyReason.
 */
enum class UnderratedEmptyReason(val wire: String) {
    /** The web is follows only (the wider network was never built): nobody can be one step out. */
    WEB_INCOMPLETE("web_incomplete"),
    /** The web is whole and still nothing cleared the bar. */
    NOTHING_QUALIFIED("nothing_qualified"),
    /** The trust graph is not built yet: the relay withholds the feed. */
    WEB_NOT_READY("web_not_ready");

    companion object {
        /** The reason in a relay answer; null for a list of notes, an error, or a reason this build doesn't know. */
        fun parse(json: String?): UnderratedEmptyReason? {
            val text = json?.trim() ?: return null
            if (!text.startsWith("{")) return null
            val raw = runCatching {
                (kotlinx.serialization.json.Json.parseToJsonElement(text) as? kotlinx.serialization.json.JsonObject)
                    ?.get("reason")?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            }.getOrNull() ?: return null
            return entries.firstOrNull { it.wire == raw }
        }
    }
}

/**
 * Underrated's empty screen from the reason the relay gave (iOS UnderratedEmptyState). A follows-only web offers to
 * build the wider network (the Vault's `wider_network` job, ImportJobService); anything else keeps today's Refresh
 * Feed and words (null overrides). Popular and Catch Up never read this.
 */
data class UnderratedEmptyState(val title: String?, val subtitle: String?, val action: Action) {
    enum class Action { REFRESH_FEED, BUILD_WIDER_NETWORK, BUILDING_WIDER_NETWORK }

    companion object {
        const val WIDER_WEB_TITLE = "Underrated needs your wider web"
        const val WIDER_WEB_SUBTITLE = "Underrated shows people your follows follow, and your vault only knows your follows so far."
        const val BUILD_TITLE = "Build your wider network"
        const val BUILDING_TITLE = "Building your wider network\u2026"
        const val REFRESH_TITLE = "Refresh Feed"

        fun of(reason: UnderratedEmptyReason?, building: Boolean): UnderratedEmptyState = when {
            building -> UnderratedEmptyState(WIDER_WEB_TITLE, WIDER_WEB_SUBTITLE, Action.BUILDING_WIDER_NETWORK)
            reason == UnderratedEmptyReason.WEB_INCOMPLETE ->
                UnderratedEmptyState(WIDER_WEB_TITLE, WIDER_WEB_SUBTITLE, Action.BUILD_WIDER_NETWORK)
            else -> UnderratedEmptyState(null, null, Action.REFRESH_FEED)
        }
    }
}

/**
 * Computes [mode] on the relay. One computation per feed at a time: a second
 * pull or tab tap would race the first, and whichever landed last would win
 * (iOS loadPopularFeed). Each feed has its own guard, so leaving Popular
 * mid-compute for Catch Up still computes Catch Up.
 */
internal fun FeedService.loadLocalDvmFeed(mode: FeedMode) {
    if (!mode.isLocalDvm) return
    // Catch Up with no follow list known yet (a launch straight into it):
    // load the list first, then compute, instead of computing for nobody
    // (iOS FeedService.dvmCompute).
    if (mode == FeedMode.CATCH_UP && _followedPubkeys.value.isEmpty() && !_hasAttemptedContactLoad.value) {
        scope.launch {
            if (!_isLoadingContacts.value) loadContactList()
            _isLoadingContacts.first { !it }
            if (_feedMode.value == FeedMode.CATCH_UP && _hasAttemptedContactLoad.value) loadLocalDvmFeed(FeedMode.CATCH_UP)
        }
        return
    }
    if (!localDvmLoading.add(mode)) return
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
            // Underrated's empty answer says why ({"reason": ...}).
            val emptyReason = if (mode == FeedMode.UNDERRATED) UnderratedEmptyReason.parse(resultJson) else null
            if (emptyReason != null) {
                withContext(Dispatchers.Main.immediate) {
                    if (nostrService.activeHexPubkey == account) _underratedEmptyReason.value = emptyReason
                }
                emptyList<FeedNote>() to emptyMap()
            } else if (resultJson.isNullOrEmpty()) {
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
            if (mode == FeedMode.UNDERRATED && notes.isNotEmpty()) _underratedEmptyReason.value = null
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
