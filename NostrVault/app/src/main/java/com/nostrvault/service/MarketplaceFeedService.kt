package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.MarketCategory
import com.nostrvault.data.model.MarketListing
import com.nostrvault.data.model.MarketListingBook
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Marketplace listings: NIP-15 products/auctions (30018/30020) and NIP-99
 * classifieds (30402), parsed by [MarketListing]. Mirrors
 * MarketplaceFeedService.swift, and is shaped like [LiveFeedService]: its own
 * short-lived connections to the marketplace relays, results in memory only.
 */
@Singleton
class MarketplaceFeedService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) {
    companion object {
        private const val TAG = "MarketplaceFeedService"
        private const val LIMIT = 200
        /** Authors per REQ filter; relays reject very large filters (iOS `trustedAuthorsCap`). */
        const val AUTHORS_CAP = 500

        /**
         * REQ filters for one load (iOS `trustScopedFilters`). Under the Web of
         * Trust the same filter is asked twice: once naming trusted authors, so a
         * page of strangers cannot crowd out the people Global will show, and
         * once open, for trusted authors past the cap. The collector still drops
         * untrusted authors from both.
         */
        fun filters(kinds: List<Int>, authors: List<String>?, trust: Set<String>?): List<String> {
            fun filter(names: List<String>?): String {
                val authorsJson = names?.let { list -> ",\"authors\":[${list.joinToString(",") { "\"$it\"" }}]" } ?: ""
                return """{"kinds":[${kinds.joinToString(",")}]$authorsJson,"limit":$LIMIT}"""
            }
            if (authors != null) return listOf(filter(authors))
            if (trust.isNullOrEmpty()) return listOf(filter(null))
            return listOf(filter(trust.sorted().take(AUTHORS_CAP)), filter(null))
        }
        /** Same window as [LiveFeedService.COLLECT_WINDOW_MS], for the same reason. */
        private const val COLLECT_WINDOW_MS = 20_000L
        /** Results older than this are refetched when the feed is opened again. */
        private const val STALE_AFTER_MS = 10 * 60 * 1000L

        /**
         * The MyNostrSpace marketplace relay set plus relay.primal.net, which
         * returned a full page on 2026-10-04 while nos.lol and relay.nostr.net
         * timed out. nos.lol was dropped on 2026-10-12. relay.conduit.market
         * is Conduit's marketplace relay (2026-10-17): its page added 170
         * listings the others lack; most of its listings are throwaway-key
         * test posts, which Global's trust filter keeps out. nostr.mom,
         * nos.lol and relay.plebeian.market are where the new Plebeian
         * Market posts (Tara's check, 2026-10-22); nos.lol is back for that.
         * Same list as the Swift side.
         */
        val RELAYS = listOf(
            "wss://relay.damus.io",
            "wss://relay.snort.social",
            "wss://relay.nostr.net",
            "wss://nostr.wine",
            "wss://relay.primal.net",
            "wss://relay.conduit.market",
            "wss://relay.plebeian.market",
            "wss://nostr.mom",
            "wss://nos.lol",
        )
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    /** Newest-first, one per `kind:pubkey:d` address. */
    private val _listings = MutableStateFlow<List<MarketListing>>(emptyList())
    val listings: StateFlow<List<MarketListing>> = _listings.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    /** No relay connected during the last load, so an empty grid is not "nothing for sale". */
    private val _loadFailed = MutableStateFlow(false)
    val loadFailed: StateFlow<Boolean> = _loadFailed.asStateFlow()

    /** Selected category chip, or null for "All". */
    private val _selectedCategory = MutableStateFlow<MarketCategory?>(null)
    val selectedCategory: StateFlow<MarketCategory?> = _selectedCategory.asStateFlow()

    /**
     * Following by default (Logen 2026-10-22): Global shows sellers from
     * anywhere on Nostr and is reached through the global warning
     * ([MarketScopeGate]). An empty Following grid offers the switch.
     */
    private val _scope = MutableStateFlow(MarketScopeGate.OPENS_ON)
    val listingScope: StateFlow<ReelsScope> = _scope.asStateFlow()

    /** Global was asked for: the screen shows the global warning, and Proceed calls [confirmGlobal]. */
    private val _globalWarningPending = MutableStateFlow(false)
    val globalWarningPending: StateFlow<Boolean> = _globalWarningPending.asStateFlow()

    /** True when Following is selected and the owner follows nobody. */
    private val _followSetIsEmpty = MutableStateFlow(false)
    val followSetIsEmpty: StateFlow<Boolean> = _followSetIsEmpty.asStateFlow()

    private var clients = mutableListOf<WebSocketClient>()
    private var job: Job? = null
    private var lastLoadedAt = 0L

    /** Following switches at once; Global waits for the warning ([MarketScopeGate]). */
    fun setScope(newScope: ReelsScope) {
        when (MarketScopeGate.request(newScope, _scope.value)) {
            MarketScopeGate.Action.NONE -> Unit
            MarketScopeGate.Action.WARN -> _globalWarningPending.value = true
            MarketScopeGate.Action.SWITCH -> switchScope(newScope)
        }
    }

    /** Proceed on the global warning. */
    fun confirmGlobal() {
        _globalWarningPending.value = false
        switchScope(ReelsScope.GLOBAL)
    }

    /** Cancel on the global warning: stay where it was. */
    fun cancelGlobal() {
        _globalWarningPending.value = false
    }

    private fun switchScope(newScope: ReelsScope) {
        if (newScope == _scope.value) return
        _scope.value = newScope
        _listings.value = emptyList()
        refresh()
    }

    fun selectCategory(category: MarketCategory?) {
        _selectedCategory.value = category
    }

    /** Loads on first open, and again once the results have gone stale. */
    fun loadIfNeeded() {
        if (_isLoading.value) return
        val fresh = System.currentTimeMillis() - lastLoadedAt < STALE_AFTER_MS
        if (fresh && _listings.value.isNotEmpty()) return
        refresh()
    }

    fun refresh() {
        job?.cancel()
        disconnect()
        _isLoading.value = true
        _followSetIsEmpty.value = false
        _loadFailed.value = false

        // An `authors: []` REQ matches nothing and would look like a dead
        // feed, so say what is actually true instead.
        var authors: List<String>? = null
        // Global follows the app-wide shield: Web of Trust, or everyone.
        val trust = if (_scope.value == ReelsScope.GLOBAL) feedService.globalTrustSet() else null
        if (_scope.value == ReelsScope.FOLLOWING) {
            val follows = feedService.followedPubkeys.value
            if (follows.isEmpty()) {
                _isLoading.value = false
                _followSetIsEmpty.value = true
                return
            }
            authors = feedService.feedAuthors()
        }

        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        val subId = "market-${System.currentTimeMillis().toString(36)}"
        val req = "[\"REQ\",\"$subId\",${filters(MarketListing.KINDS, authors, trust).joinToString(",")}]"
        // Addressable: the newest event at an address wins, including a
        // re-publish marking the item sold. Same mutex-and-snapshot pattern as
        // LiveFeedService, for the same ConcurrentModificationException.
        val book = MarketListingBook()
        val bookLock = Mutex()
        // Any relay that connected answered the question, even with nothing.
        val reached = java.util.concurrent.atomic.AtomicBoolean(false)

        job = scope.launch {
            for (url in RELAYS) {
                val client = WebSocketClient(url, scope)
                clients.add(client)
                launch {
                    client.messages.collect { raw ->
                        val e = parseListingEvent(json, raw, subId) ?: return@collect
                        if (e.pubkey in blocked) return@collect
                        if (trust != null && e.pubkey !in trust) return@collect
                        val snapshot = bookLock.withLock {
                            if (book.insert(e.id, e.pubkey, e.kind, e.content, e.createdAt, e.tags)) book.listings else null
                        }
                        snapshot?.let { publish(it) }
                    }
                }
                launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            reached.set(true)
                            client.send(req)
                        }
                    }
                }
                client.connect()
            }

            delay(COLLECT_WINDOW_MS)
            _isLoading.value = false
            _loadFailed.value = !reached.get() && _listings.value.isEmpty()
            disconnect()
        }
    }

    fun disconnect() {
        clients.forEach { it.disconnect() }
        clients.clear()
    }

    private fun publish(values: Collection<MarketListing>) {
        val sorted = values.sortedWith(compareByDescending<MarketListing> { it.createdAt }.thenByDescending { it.id })
        _listings.value = sorted
        lastLoadedAt = System.currentTimeMillis()
        // A chip whose category vanished from the results would show nothing.
        val selected = _selectedCategory.value
        if (selected != null && sorted.none { it.category == selected }) _selectedCategory.value = null
    }
}

/** One listing-kind event off the wire, before [MarketListingBook] judges it. */
internal data class RelayListingEvent(
    val id: String,
    val pubkey: String,
    val kind: Int,
    val content: String,
    val createdAt: Long,
    val tags: List<List<String>>,
)

/** @return the event in this relay message for [expectedSubId], or null. */
internal fun parseListingEvent(json: Json, raw: String, expectedSubId: String): RelayListingEvent? = try {
    val array = json.parseToJsonElement(raw) as? JsonArray
    if (array == null || array.size < 3 ||
        array[0].jsonPrimitive.content != "EVENT" ||
        array[1].jsonPrimitive.content != expectedSubId
    ) {
        null
    } else {
        val event = array[2].jsonObject
        RelayListingEvent(
            id = event["id"]?.jsonPrimitive?.content.orEmpty(),
            pubkey = event["pubkey"]?.jsonPrimitive?.content.orEmpty(),
            kind = event["kind"]?.jsonPrimitive?.content?.toIntOrNull() ?: 0,
            content = event["content"]?.jsonPrimitive?.content.orEmpty(),
            createdAt = event["created_at"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
            tags = event["tags"]?.jsonArray?.map { tag ->
                tag.jsonArray.map { it.jsonPrimitive.content }
            } ?: emptyList(),
        )
    }
} catch (e: Exception) {
    Log.w("MarketplaceFeedService", "unparseable relay message: ${e.message}")
    null
}

/**
 * Marketplace's Following / Global switch (Logen 2026-10-22): it opens on Following, and Global,
 * which shows sellers from anywhere on Nostr, waits for the global feed warning. Pure for the
 * tests. iOS: MarketScopeGate.swift.
 */
internal object MarketScopeGate {
    val OPENS_ON = ReelsScope.FOLLOWING

    enum class Action { NONE, SWITCH, WARN }

    fun request(target: ReelsScope, current: ReelsScope): Action = when {
        target == current -> Action.NONE
        target == ReelsScope.GLOBAL -> Action.WARN
        else -> Action.SWITCH
    }
}
