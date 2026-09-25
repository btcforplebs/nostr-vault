package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.Reel
import com.nostrvault.data.model.ReelCursors
import com.nostrvault.data.model.ReelStream
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Reels: one playable video per page, swiped vertically. Port of iOS
 * `ReelsFeedService`, shaped like [LiveFeedService]: its own short-lived relay
 * connections, never the note subscription.
 *
 * Two sources feed it. NIP-71 video events (kinds 21/22 and their addressable
 * 34235/34236 forms) are video by definition. Ordinary kind-1 notes are where
 * most video on Nostr actually lives, so they are fetched too and kept only
 * when a URL in them is known to be video — see [Reel.from].
 *
 * Threading: relay messages are parsed on a background dispatcher, one
 * collector per relay, and every piece of paging state is read and written
 * under [lock]. Hopping each event to the main thread instead would let a
 * relay's burst overrun [WebSocketClient]'s message buffer, which drops rather
 * than waits. Every fetch carries a generation number, so a message or timeout
 * from a torn-down page can never touch the current one.
 */
@Singleton
class ReelsFeedService @Inject constructor(
    @ApplicationContext context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val mediaTypeDetector: MediaTypeDetector,
) {
    companion object {
        private const val TAG = "ReelsFeedService"

        /**
         * How long one page may wait on relays that have not answered. A page
         * every relay has answered finishes at once; this only bounds a dead
         * one. Longer than iOS's 10s: on the phone, five sockets doing DNS, TLS
         * and a REQ were measured connecting as late as t+5s (see
         * [LiveFeedService.COLLECT_WINDOW_MS]'s note).
         */
        private const val PAGE_TIMEOUT_MS = 15_000L

        /** Events arrive one message at a time from several relays; batch them. */
        private const val PUBLISH_DEBOUNCE_MS = 350L

        private const val PREFS_NAME = "reels_preferences"
        private const val KEY_MUTED = "reels_muted"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // ── Observable state ──────────────────────────────────────────────

    private val _reels = MutableStateFlow<List<Reel>>(emptyList())
    /** Playable reels in play order. */
    val reels: StateFlow<List<Reel>> = _reels.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    /** The first page is still being fetched. */
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    private val _loadFailed = MutableStateFlow(false)
    val loadFailed: StateFlow<Boolean> = _loadFailed.asStateFlow()

    private val _followSetIsEmpty = MutableStateFlow(false)
    val followSetIsEmpty: StateFlow<Boolean> = _followSetIsEmpty.asStateFlow()

    private val _scope = MutableStateFlow(ReelsScope.FOLLOWING)
    /**
     * Following by default. Global video is unmoderated third-party content,
     * so it is opt-in behind the sensitive-content warning.
     */
    val reelsScope: StateFlow<ReelsScope> = _scope.asStateFlow()

    private val _isMuted = MutableStateFlow(prefs.getBoolean(KEY_MUTED, false))
    /** Sound follows the viewer from reel to reel and across launches. */
    val isMuted: StateFlow<Boolean> = _isMuted.asStateFlow()

    // ── Paging state (guarded by lock) ────────────────────────────────

    private val lock = Any()
    private var generation = 0
    private val clients = mutableListOf<WebSocketClient>()
    private val clientJobs = mutableListOf<Job>()
    private var timeoutJob: Job? = null
    private var publishJob: Job? = null

    private val collected = HashMap<String, Reel>()
    private val seenVideoUrls = HashSet<String>()
    /**
     * Once the viewer has swiped past the first reel the order is frozen:
     * arrivals are appended instead of sorted in, so the video under their
     * thumb never jumps.
     */
    private var orderIsFrozen = false
    private var shownReelId: String? = null

    private var cursors = ReelCursors()
    /** Per relay index, per stream: the oldest event this page returned. */
    private val pageOldest = HashMap<Int, MutableMap<ReelStream, Long>>()
    /** Relays that have finished this page (EOSE or CLOSED). */
    private val answered = HashSet<Int>()
    private var countBeforeFetch = 0

    private val isFetching: Boolean get() = clients.isNotEmpty()

    // ── Public API ────────────────────────────────────────────────────

    fun setScope(newScope: ReelsScope) {
        synchronized(lock) {
            if (newScope == _scope.value) return
            _scope.value = newScope
            refreshLocked()
        }
    }

    fun setMuted(muted: Boolean) {
        _isMuted.value = muted
        prefs.edit().putBoolean(KEY_MUTED, muted).apply()
    }

    fun loadIfNeeded() {
        synchronized(lock) {
            if (isFetching || _reels.value.isNotEmpty()) return
            refreshLocked()
        }
    }

    fun refresh() {
        synchronized(lock) { refreshLocked() }
    }

    /**
     * Called as the viewer nears the end of what is loaded. A page still in
     * flight is left alone — starting another would cut off the relays that
     * have not answered yet.
     */
    fun loadMore() {
        synchronized(lock) {
            if (isFetching || cursors.reachedEnd || _reels.value.isEmpty()) return
            _isLoadingMore.value = true
            fetchLocked()
        }
    }

    /** The view reports the reel on screen; leaving the first one freezes order. */
    fun didShow(reelId: String) {
        synchronized(lock) {
            shownReelId = reelId
            val first = _reels.value.firstOrNull()
            if (!orderIsFrozen && first != null && first.id != reelId) orderIsFrozen = true
        }
    }

    /** Stops the page in flight. Leaving the mode calls this. */
    fun disconnect() {
        synchronized(lock) {
            disconnectLocked()
            _isLoading.value = false
            _isLoadingMore.value = false
        }
    }

    /** Drops reels by anyone blocked since they were fetched. */
    fun pruneBlocked() {
        synchronized(lock) {
            val blocked = blockedHex()
            if (blocked.isEmpty() || _reels.value.none { it.note.pubkey in blocked }) return
            collected.values.removeAll { it.note.pubkey in blocked }
            _reels.value = _reels.value.filter { it.note.pubkey !in blocked }
        }
    }

    // ── Fetching (call with lock held) ────────────────────────────────

    private fun refreshLocked() {
        disconnectLocked()
        collected.clear()
        seenVideoUrls.clear()
        _reels.value = emptyList()
        orderIsFrozen = false
        shownReelId = null
        cursors = ReelCursors()
        _loadFailed.value = false
        _followSetIsEmpty.value = false
        _isLoadingMore.value = false
        _isLoading.value = true
        fetchLocked()
    }

    private fun disconnectLocked() {
        // Bumping the generation is what makes late messages and timers from
        // the old page harmless; cancelling is what stops the work.
        generation++
        timeoutJob?.cancel()
        timeoutJob = null
        publishJob?.cancel()
        publishJob = null
        clientJobs.forEach { it.cancel() }
        clientJobs.clear()
        clients.forEach { it.disconnect() }
        clients.clear()
    }

    private fun fetchLocked() {
        disconnectLocked()
        val gen = generation

        val authors: List<String>? = if (_scope.value == ReelsScope.FOLLOWING) {
            val follows = feedService.followedPubkeys.value
            if (follows.isEmpty()) {
                _isLoading.value = false
                _isLoadingMore.value = false
                _followSetIsEmpty.value = true
                return
            }
            follows
        } else {
            null
        }

        val filters = cursors.filters(authors)
        if (filters.isEmpty()) {
            _isLoading.value = false
            _isLoadingMore.value = false
            return
        }

        val relayUrls = relayUrls(_scope.value)
        if (relayUrls.isEmpty()) {
            _isLoading.value = false
            _isLoadingMore.value = false
            _loadFailed.value = true
            return
        }

        val subId = "reels-${System.nanoTime().toString(36).takeLast(8)}"
        val req = "[\"REQ\",\"$subId\",${filters.joinToString(",")}]"
        val blocked = blockedHex()
        countBeforeFetch = collected.size
        answered.clear()
        pageOldest.clear()

        for ((relayIndex, url) in relayUrls.withIndex()) {
            val client = WebSocketClient(
                url = url,
                scope = scope,
                trustLocalhost = url.contains("localhost") || url.contains("127.0.0.1"),
            )
            clients += client
            clientJobs += scope.launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                client.messages.collect { raw -> onMessage(raw, subId, relayIndex, gen, blocked) }
            }
            clientJobs += scope.launch {
                client.connectionState.collect { state ->
                    if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(req)
                }
            }
            client.connect()
        }

        timeoutJob = scope.launch {
            delay(PAGE_TIMEOUT_MS)
            synchronized(lock) { finishPageLocked(gen) }
        }
    }

    /**
     * The device's own relay (and its feed cache) answer first and hold the
     * follow set's history; the feed relays fill in the rest.
     */
    private fun relayUrls(scope: ReelsScope): List<String> {
        val config = configStore.config.value
        return buildList {
            if (scope == ReelsScope.FOLLOWING && RelayForegroundService.readyForConnections.value) {
                config.nostrURL?.let(::add)
                config.localRelayURL("feed")?.let(::add)
            }
            addAll(config.activeFeedRelays.ifEmpty { listOf("wss://relay.primal.net", "wss://nos.lol") })
        }.distinct()
    }

    private fun blockedHex(): Set<String> = configStore.config.value.blockedForActiveAccount()
        .mapNotNull { nostrService.npubToHex(it) }
        .toSet()

    // ── Messages (background dispatcher) ──────────────────────────────

    private fun onMessage(raw: String, subId: String, relay: Int, gen: Int, blocked: Set<String>) {
        val array = try {
            json.parseToJsonElement(raw) as? JsonArray
        } catch (e: Exception) {
            Log.w(TAG, "unparseable relay message: ${e.message}")
            null
        } ?: return
        if (array.size < 2) return
        val type = array[0].jsonPrimitive.contentOrNull
        if (array[1].jsonPrimitive.contentOrNull != subId) return

        when (type) {
            "EOSE", "CLOSED" -> synchronized(lock) {
                if (gen != generation) return
                answered += relay
                // Every relay has answered — no reason to sit out the timeout.
                if (answered.size >= clients.size) finishPageLocked(gen) else schedulePublishLocked(immediate = true)
            }
            "EVENT" -> {
                val event = array.getOrNull(2) as? JsonObject ?: return
                val reel = parseEvent(event, blocked) ?: return
                synchronized(lock) {
                    if (gen != generation) return
                    val oldest = pageOldest.getOrPut(relay) { mutableMapOf() }
                    oldest[reel.stream] = minOf(oldest[reel.stream] ?: reel.createdAt, reel.createdAt)

                    val candidate = reel.reel ?: return
                    if (collected.containsKey(candidate.id)) return
                    // The same clip re-posted, or a NIP-71 event and the note announcing it.
                    if (!seenVideoUrls.add(candidate.videoUrl)) return
                    collected[candidate.id] = candidate
                    schedulePublishLocked(immediate = false)
                }
            }
        }
    }

    /** What one EVENT contributes: its paging position always, a reel when it has one. */
    private class ParsedEvent(val stream: ReelStream, val createdAt: Long, val reel: Reel?)

    private fun parseEvent(event: JsonObject, blocked: Set<String>): ParsedEvent? = try {
        val kind = event["kind"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val stream = kind?.let(ReelStream::forKind)
        val id = event["id"]?.jsonPrimitive?.contentOrNull
        val pubkey = event["pubkey"]?.jsonPrimitive?.contentOrNull
        val createdAt = event["created_at"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
        if (stream == null || id == null || pubkey == null || createdAt == null) {
            null
        } else {
            // A blocked author's event still marks how far this relay got.
            val reel = if (pubkey in blocked) {
                null
            } else {
                val tags = event["tags"]?.jsonArray?.map { tag ->
                    tag.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() }
                } ?: emptyList()
                val note = FeedNote.fromEvent(
                    id = id,
                    pubkey = pubkey,
                    content = event["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    tags = tags,
                    createdAt = createdAt,
                    kind = kind!!,
                )
                Reel.from(note, createdAt, mediaTypeDetector::getCachedContentType)
            }
            ParsedEvent(stream, createdAt, reel)
        }
    } catch (e: Exception) {
        Log.w(TAG, "unusable event: ${e.message}")
        null
    }

    // ── Publishing (call with lock held) ──────────────────────────────

    private fun schedulePublishLocked(immediate: Boolean) {
        publishJob?.cancel()
        val gen = generation
        publishJob = scope.launch(Dispatchers.Default) {
            if (!immediate) delay(PUBLISH_DEBOUNCE_MS)
            synchronized(lock) { if (gen == generation) publishLocked() }
        }
    }

    private fun publishLocked() {
        val current = _reels.value
        if (orderIsFrozen) {
            val shown = current.mapTo(HashSet()) { it.id }
            val arrivals = collected.values.filter { it.id !in shown }.sortedWith(Reel.NEWEST_FIRST)
            if (arrivals.isNotEmpty()) _reels.value = current + arrivals
        } else {
            _reels.value = collected.values.sortedWith(Reel.NEWEST_FIRST)
        }
    }

    private fun finishPageLocked(gen: Int) {
        if (gen != generation || !isFetching) return
        publishLocked()

        // No relay answered at all: a network failure, not the end of
        // history. Leave the cursors alone so a later swipe can retry.
        if (pageOldest.isEmpty() && answered.isEmpty()) {
            disconnectLocked()
            _isLoading.value = false
            _isLoadingMore.value = false
            _loadFailed.value = _reels.value.isEmpty() && !_followSetIsEmpty.value
            return
        }

        cursors = cursors.afterPage(pageOldest.values, producedReels = collected.size > countBeforeFetch)
        disconnectLocked()
        _isLoading.value = false
        _isLoadingMore.value = false
        _loadFailed.value = false

        // Keep paging while the viewer is already near the end — nothing else
        // would trigger the next page once the pager sits on its last reel.
        val reels = _reels.value
        val shownIndex = shownReelId?.let { id -> reels.indexOfFirst { it.id == id } }?.takeIf { it >= 0 } ?: 0
        if (ReelCursors.shouldContinue(reels.size, shownIndex, cursors.reachedEnd)) {
            if (reels.isEmpty()) _isLoading.value = true else _isLoadingMore.value = true
            fetchLocked()
        }
    }
}
