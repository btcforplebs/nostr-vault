package com.nostrvault.ui.screens.feed

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.DashboardEvent
import com.nostrvault.data.model.FeedDashboardSnapshot
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.MarketListing
import com.nostrvault.data.model.Reel
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.LiveFeedService
import com.nostrvault.service.MarketplaceFeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ReelsFeedService
import com.nostrvault.service.StatsService
import com.nostrvault.util.ZapDetail.Companion.parseTags
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject

/**
 * Loads the feed dashboard: your follows' last 24 hours. One query per relay
 * group, all filtered to follows and the last day; every card is derived from
 * that one result. It does not start the Live, Marketplace or diVines
 * services, so opening it never changes what those feeds show. Port of iOS
 * FeedDashboardStore.
 */
@HiltViewModel
class FeedDashboardViewModel @Inject constructor(
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val liveFeedService: LiveFeedService,
    private val marketplaceFeedService: MarketplaceFeedService,
    private val reelsFeedService: ReelsFeedService,
    statsService: StatsService,
) : ViewModel() {

    private val _snapshot = MutableStateFlow(cached)
    val snapshot: StateFlow<FeedDashboardSnapshot?> = _snapshot.asStateFlow()
    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()
    private val _followSetIsEmpty = MutableStateFlow(false)
    val followSetIsEmpty: StateFlow<Boolean> = _followSetIsEmpty.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val loadedEventsCount: StateFlow<Int> = statsService.loadedEventsCount
    val wotPubkeys: StateFlow<Set<String>> = feedService.wotPubkeys

    private var generation = 0

    init { loadIfNeeded() }

    fun loadIfNeeded() {
        val fresh = System.currentTimeMillis() - cachedAt < STALE_AFTER_MS
        if (cached != null && cachedAccount == nostrService.activeHexPubkey && fresh) return
        refresh()
    }

    fun refresh() {
        val gen = ++generation
        val owner = nostrService.activeHexPubkey
        if (cachedAccount != owner) _snapshot.value = null
        val follows = feedService.followedPubkeys.value
        _followSetIsEmpty.value = follows.isEmpty()
        if (follows.isEmpty() && owner.isEmpty()) return
        _isLoading.value = true

        viewModelScope.launch {
            val now = System.currentTimeMillis() / 1000
            val since = now - FeedDashboardSnapshot.WINDOW_SECONDS
            val config = configStore.config.value
            val feedRelays = config.readRelays.distinct().take(6)
            val ownRelays = listOfNotNull(config.nostrURL, config.localInboxURL).plus(config.readRelays).distinct().take(6)
            val marketRelays = MarketplaceFeedService.RELAYS.take(6)
            val reelRelays = (listOf(Reel.DIVINE_RELAY) + config.readRelays).distinct().take(6)
            val chunks = follows.chunked(AUTHORS_PER_FILTER)
            fun byFollows(kinds: List<Int>, limit: Int, tag: String = "authors") = chunks.map { chunk ->
                """{"kinds":${kinds.joinToString(",", "[", "]")},"$tag":${chunk.joinToString(",", "[", "]") { "\"$it\"" }},"since":$since,"limit":$limit}"""
            }

            val notes = async {
                if (follows.isEmpty()) emptyList()
                else query(
                    byFollows(listOf(1, 6), 1500) + byFollows(listOf(7), 1500) +
                        byFollows(listOf(FeedDashboardSnapshot.POLL_KIND, FeedDashboardSnapshot.ARTICLE_KIND), 200),
                    feedRelays,
                )
            }
            val reels = async {
                if (follows.isEmpty()) emptyList() else query(byFollows(listOf(FeedDashboardSnapshot.DIVINE_KIND), 100), reelRelays)
            }
            val listings = async {
                if (follows.isEmpty()) emptyList() else query(byFollows(MarketListing.KINDS, 100), marketRelays)
            }
            val live = async {
                if (follows.isEmpty()) emptyList()
                else query(byFollows(listOf(LiveStream.KIND), 100) + byFollows(listOf(LiveStream.KIND), 100, "#p"), feedRelays)
            }
            val zaps = async {
                if (owner.isEmpty()) emptyList()
                else query(listOf("""{"kinds":[9735],"#p":["$owner"],"since":$since,"limit":500}"""), ownRelays)
            }
            val followers = async(Dispatchers.IO) {
                runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(owner)) }.getOrNull()
            }

            val built = withContext(Dispatchers.Default) {
                FeedDashboardSnapshot.build(
                    events = notes.await() + reels.await() + listings.await() + live.await(),
                    zapReceipts = zaps.await(),
                    followers = followers.await(),
                    follows = follows.toSet(),
                    owner = owner,
                    blocked = feedService.blockedHexForActiveAccount(),
                    since = since,
                    now = now,
                )
            }
            if (gen != generation) return@launch
            publish(built, owner)
            _isLoading.value = false
            nostrService.fetchMissingProfiles(built.profilePubkeys)

            // The most-liked posts are often older than a day, or by someone
            // you do not follow: fetch the ones the load did not bring.
            val missing = built.popular.filter { it.note == null }.map { it.id }
            if (missing.isNotEmpty()) {
                val ids = missing.joinToString(",") { "\"$it\"" }
                val found = query(listOf("""{"ids":[$ids],"limit":${missing.size}}"""), feedRelays)
                if (gen != generation) return@launch
                val withNotes = built.withPopularNotes(found)
                publish(withNotes, owner)
                nostrService.fetchMissingProfiles(withNotes.profilePubkeys)
            }
        }
    }

    /**
     * A tile or stat opens its feed on Following: the dashboard is about the
     * people you follow, so Global would show something else.
     */
    fun openOnFollowing(mode: FeedMode) {
        when (mode) {
            FeedMode.MARKETPLACE -> marketplaceFeedService.setScope(ReelsScope.FOLLOWING)
            FeedMode.REELS -> reelsFeedService.setScope(ReelsScope.FOLLOWING)
            FeedMode.LIVE -> liveFeedService.setScope(ReelsScope.FOLLOWING)
            FeedMode.POLLS -> feedService.setLongFormFeedMode(mode, com.nostrvault.data.model.MediaFeedMode.FOLLOWING)
            else -> Unit
        }
        if (feedService.feedMode.value != mode) feedService.switchMode(mode)
    }

    private fun publish(snapshot: FeedDashboardSnapshot, owner: String) {
        _snapshot.value = snapshot
        cached = snapshot
        cachedAt = System.currentTimeMillis()
        cachedAccount = owner
    }

    /** Signature-checked: a relay is not trusted. */
    private suspend fun query(filters: List<String>, relays: List<String>): List<DashboardEvent> {
        if (filters.isEmpty() || relays.isEmpty()) return emptyList()
        val raw = nostrService.queryRawEvents(filters, relays, timeoutMs = 8_000L)
        return withContext(Dispatchers.Default) {
            raw.mapNotNull { e -> e.toDashboardEvent()?.takeIf { HavenBridge.verifyEvent(e.toString()) } }
        }
    }

    private fun JsonObject.toDashboardEvent(): DashboardEvent? {
        fun str(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        return DashboardEvent(
            id = str("id") ?: return null,
            pubkey = str("pubkey") ?: return null,
            kind = (this["kind"] as? JsonPrimitive)?.intOrNull ?: return null,
            createdAt = (this["created_at"] as? JsonPrimitive)?.longOrNull ?: return null,
            content = str("content") ?: "",
            tags = parseTags(this["tags"]),
        )
    }

    private companion object {
        /** Relays reject very large author lists. */
        const val AUTHORS_PER_FILTER = 500
        const val STALE_AFTER_MS = 5 * 60 * 1000L

        // Kept across screen visits, like the mode feeds: reopening within a
        // few minutes shows the last result instead of loading again.
        var cached: FeedDashboardSnapshot? = null
        var cachedAt = 0L
        var cachedAccount: String? = null
    }
}
