package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.ArticleEngagement
import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.data.model.ArticleTallies
import com.nostrvault.data.model.ArticleTally
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.ZapSendService
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Optional
import javax.inject.Inject

/**
 * Reader for one NIP-23 long-form post.
 *
 * A kind-30023 body is Markdown, and rendering it as the plain text a kind-1
 * note gets would show the reader the syntax instead of the article. The
 * markdown renderer was already a dependency of this project and was not being
 * used anywhere.
 */
@HiltViewModel
class ArticleReaderViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val zapSendService: ZapSendService,
    val gatedArticles: com.nostrvault.service.GatedArticleService,
    private val notificationManager: com.nostrvault.ui.notification.NotificationManager,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    private companion object {
        /** Highlights already fetched this session, by article id. */
        val highlightCache = ConcurrentHashMap<String, List<ArticleHighlight>>()
        /** Likes, zaps and comments fetched this session, by article id. */
        val engagementCache = ConcurrentHashMap<String, List<ArticleEngagementEvent>>()
    }

    private val _note = MutableStateFlow<FeedNote?>(null)
    val note: StateFlow<FeedNote?> = _note.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds

    /**
     * The active account's blocked people (hex), kept current so a block made
     * while the article is open takes their highlights and comments out at once.
     */
    private val blockedPubkeys: StateFlow<Set<String>> = configStore.config
        .map { feedService.blockedHexForActiveAccount() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, feedService.blockedHexForActiveAccount())

    private val _zapped = MutableStateFlow(false)
    val zapped: StateFlow<Boolean> = _zapped.asStateFlow()

    /** Sats you zapped from this screen, counted before the receipt arrives. */
    private val _zappedSats = MutableStateFlow(0L)
    val zappedSats: StateFlow<Long> = _zappedSats.asStateFlow()

    val myPubkey: String get() = configStore.activeAccountHexPubkey.value
    /** Wallet settings' default zap, in sats: where the zap sheet starts. */
    val defaultZapSats: Int get() = configStore.config.value.defaultZapAmount

    private val relayHint: String get() = configStore.config.value.nostrURL ?: ""

    /** Same optimistic like as the feed, tagged with the article's `a` coordinate. */
    fun like(note: FeedNote) {
        feedService.likeNote(
            note.id,
            tags = ArticleEngagement.reactionTags(note.id, note.kind, note.pubkey, note.tags, relayHint),
        )
    }

    fun zap(note: FeedNote, amountSats: Int) {
        viewModelScope.launch {
            val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags)
            // The zap pill reports the result (docs/pills.md).
            notificationManager.zapping(
                com.nostrvault.ui.screens.feed.zapRecipientName(nostrService.profiles.value, note.pubkey),
                amountSats,
            ) { zapSendService.zapNote(note.id, note.pubkey, amountSats, addressTag = coordinate) }
                .onSuccess {
                    _zapped.value = true
                    _zappedSats.update { it + amountSats }
                }
        }
    }

    fun publishHighlight(note: FeedNote, passage: String, context: String, comment: String) {
        val tags = ArticleEngagement.highlightTags(
            note.id, note.kind, note.pubkey, note.tags, relayHint, passage, context, comment,
        )
        viewModelScope.launch {
            val event = runCatching {
                nostrService.signEventAsync(kind = ArticleEngagement.HIGHLIGHT_KIND, content = passage.trim(), tags = tags)
            }.getOrNull()
            if (event != null) {
                nostrService.postEvent(event)
                notificationManager.showToast("Highlight published")
                // Show it among everyone else's once a relay has it.
                loadHighlights(note)
            } else {
                notificationManager.showError("Highlight not signed")
            }
        }
    }

    // ── Highlights from the network ──────────────────────────────────

    /** Everyone's highlights, blocked people's included, so an unblock brings them back. */
    private val _highlights = MutableStateFlow<List<ArticleHighlight>>(emptyList())
    /** Other people's highlights of this article, newest first, blocked people's left out. */
    val highlights: StateFlow<List<ArticleHighlight>> = combine(_highlights, blockedPubkeys) { found, blocked ->
        ArticleBlockFilter.visibleHighlights(found, blocked)
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /**
     * The article's relay, the feed relays and the author's outbox: where a
     * highlight of it is likely to have been sent.
     */
    private fun highlightRelays(note: FeedNote): List<String> {
        val config = configStore.config.value
        val candidates = buildList {
            config.nostrURL?.let { add(it) }
            addAll(config.readRelays)
            addAll(nostrService.outboxRelays.value[note.pubkey].orEmpty())
        }
        return candidates.map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinctBy { it.lowercase().trimEnd('/') }
            .take(8)
    }

    /**
     * Fetch highlights of [note], showing them as each relay answers rather
     * than after the slowest one, which could hold the list back for the
     * whole timeout. A reopened article shows the last result at once.
     */
    fun loadHighlights(note: FeedNote) {
        highlightCache[note.id]?.let { cached -> _highlights.update { if (cached.size >= it.size) cached else it } }
        val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags)
        // Each event is checked once, however many snapshots it appears in.
        val checked = ConcurrentHashMap<String, Optional<ArticleHighlight>>()
        fun show(events: List<JsonObject>): List<ArticleHighlight> {
            val found = ArticleEngagement.shown(events.mapNotNull { ev ->
                val id = (ev["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                checked.getOrPut(id) { Optional.ofNullable(parseHighlight(ev, note.id, coordinate)) }.orElse(null)
            })
            // An earlier, smaller snapshot can finish after a later one.
            _highlights.update { if (found.size >= it.size) found else it }
            val profiles = nostrService.profiles.value
            val shown = ArticleBlockFilter.visibleHighlights(found, blockedPubkeys.value)
            val missing = shown.map { it.pubkey }.distinct().filter { it !in profiles }
            if (missing.isNotEmpty()) nostrService.fetchMissingProfiles(missing)
            return found
        }
        viewModelScope.launch(Dispatchers.Default) {
            val events = nostrService.queryRawEvents(
                filters = ArticleEngagement.highlightFilters(note.id, coordinate),
                relayUrls = highlightRelays(note),
                onProgress = { show(it) },
            )
            highlightCache[note.id] = show(events)
        }
    }

    /** A signed 9802 that points at this article and isn't spam, or null. */
    private fun parseHighlight(ev: JsonObject, articleId: String, coordinate: String?): ArticleHighlight? {
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.contentOrNull
        val id = str("id") ?: return null
        val pubkey = str("pubkey") ?: return null
        val content = str("content") ?: return null
        val kind = (ev["kind"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.map { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        } ?: return null
        // Spam dropped the same way the thread view drops it.
        if (FeedNote.isNoiseOrSpam(content, tags)) return null
        val highlight = ArticleHighlight.from(kind, id, pubkey, content, createdAt, tags, articleId, coordinate)
            ?: return null
        return highlight.takeIf { HavenBridge.verifyEvent(ev.toString()) }
    }

    // ── Likes, zaps and comments from the network ────────────────────

    /** The last likes, zaps and comments found, blocked people's included. */
    private data class Engagement(
        val events: List<ArticleEngagementEvent> = emptyList(),
        val articleId: String = "",
        val coordinate: String? = null,
        /** Size of the tally with nobody blocked, so a block never makes a newer snapshot look smaller. */
        val size: Int = 0,
    )
    private val engagement = MutableStateFlow(Engagement())

    /** Counted after blocked people's are taken out, again whenever the block list changes. */
    val tally: StateFlow<ArticleTally> = combine(engagement, blockedPubkeys) { found, blocked ->
        tallyShown(found, blocked)
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.Eagerly, ArticleTally())

    private fun tallyShown(found: Engagement, blocked: Set<String>): ArticleTally =
        if (found.events.isEmpty()) ArticleTally()
        else ArticleTallies.tally(ArticleBlockFilter.visibleEvents(found.events, blocked), found.articleId, found.coordinate)

    /**
     * Fetch the article's likes, zaps and comments from the relays highlights
     * come from, showing each relay's answer as it lands. A reopened article
     * shows the last result at once while the relays are asked again.
     */
    fun loadEngagement(note: FeedNote) {
        val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags)
        // Each event is checked once, however many snapshots it appears in.
        val checked = ConcurrentHashMap<String, Optional<ArticleEngagementEvent>>()
        fun show(events: List<ArticleEngagementEvent>) {
            val found = Engagement(events, note.id, coordinate, ArticleTallies.tally(events, note.id, coordinate).size)
            // An earlier, smaller snapshot can finish after a later one.
            engagement.update { if (found.size >= it.size) found else it }
            val profiles = nostrService.profiles.value
            val shown = tallyShown(found, blockedPubkeys.value)
            val missing = shown.topLevelComments.map { it.pubkey }.distinct().filter { it !in profiles }
            if (missing.isNotEmpty()) nostrService.fetchMissingProfiles(missing)
        }
        fun parsed(raw: List<JsonObject>) = raw.mapNotNull { ev ->
            val id = (ev["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            checked.getOrPut(id) { Optional.ofNullable(parseEngagement(ev)) }.orElse(null)
        }
        viewModelScope.launch(Dispatchers.Default) {
            val earlier = engagementCache[note.id].orEmpty()
            if (earlier.isNotEmpty()) show(earlier)
            val events = nostrService.queryRawEvents(
                filters = ArticleTallies.engagementFilters(note.id, coordinate),
                relayUrls = highlightRelays(note),
                onProgress = { show(earlier + parsed(it)) },
            )
            // Keep what an earlier load found if a relay this time came back short.
            val merged = (earlier + parsed(events)).associateBy { it.id }.values.toList()
            engagementCache[note.id] = merged
            show(merged)
        }
    }

    /** A signed like, zap receipt or comment that isn't spam, or null. */
    private fun parseEngagement(ev: JsonObject): ArticleEngagementEvent? {
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.contentOrNull
        val id = str("id") ?: return null
        val pubkey = str("pubkey") ?: return null
        val content = str("content") ?: return null
        val kind = (ev["kind"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.map { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        } ?: return null
        // Spam comments are dropped the same way the thread view drops them.
        val isComment = kind == ArticleTallies.COMMENT_KIND || kind == ArticleTallies.NOTE_KIND
        if (isComment && FeedNote.isNoiseOrSpam(content, tags)) return null
        if (!HavenBridge.verifyEvent(ev.toString())) return null
        return ArticleEngagementEvent(id, kind, pubkey, content, createdAt, tags)
    }

    /** Makes [comment] resolvable by id for the note screen; returns that id. */
    fun prepareOpen(comment: ArticleEngagementEvent): String {
        feedService.cacheNote(comment.toNote())
        return comment.id
    }

    /** Makes [highlight] resolvable by id for the compose screen; returns that id. */
    fun prepareComment(highlight: ArticleHighlight): String {
        feedService.cacheNote(highlight.toNote())
        return highlight.id
    }

    init {
        // Same two-step the note screen uses: the in-memory feed first, then
        // the relays, so an article opened from a link rather than from the
        // list still resolves.
        val cached = feedService.findNote(noteId)
        if (cached != null) {
            _note.value = cached
        } else {
            _isLoading.value = true
            nostrService.fetchNoteById(noteId, onRawEvent = feedService::cacheRawEvent) { fetched ->
                _isLoading.value = false
                if (fetched != null) {
                    _note.value = fetched
                    feedService.cacheNote(fetched)
                }
            }
        }
    }
}
