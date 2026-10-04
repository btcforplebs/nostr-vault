package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.MarketCategory
import com.nostrvault.data.model.MarketListing
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
) {
    companion object {
        private const val TAG = "MarketplaceFeedService"
        private const val LIMIT = 200
        /** Same window as [LiveFeedService.COLLECT_WINDOW_MS], for the same reason. */
        private const val COLLECT_WINDOW_MS = 20_000L
        /** Results older than this are refetched when the feed is opened again. */
        private const val STALE_AFTER_MS = 10 * 60 * 1000L

        /**
         * The MyNostrSpace marketplace relay set plus relay.primal.net, which
         * returned a full page on 2026-10-04 while nos.lol and relay.nostr.net
         * timed out. Same list as the Swift side.
         */
        val RELAYS = listOf(
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.snort.social",
            "wss://relay.nostr.net",
            "wss://nostr.wine",
            "wss://relay.primal.net",
        )
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    /** Newest-first, one per `kind:pubkey:d` address. */
    private val _listings = MutableStateFlow<List<MarketListing>>(emptyList())
    val listings: StateFlow<List<MarketListing>> = _listings.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    /** Selected category chip, or null for "All". */
    private val _selectedCategory = MutableStateFlow<MarketCategory?>(null)
    val selectedCategory: StateFlow<MarketCategory?> = _selectedCategory.asStateFlow()

    private var clients = mutableListOf<WebSocketClient>()
    private var job: Job? = null
    private var lastLoadedAt = 0L

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

        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        val subId = "market-${System.currentTimeMillis().toString(36)}"
        val kinds = MarketListing.KINDS.joinToString(",")
        // Addressable: an edited listing arrives again under the same address,
        // so keep the newest. Same mutex-and-snapshot pattern as LiveFeedService,
        // for the same ConcurrentModificationException.
        val newest = mutableMapOf<String, MarketListing>()
        val newestLock = Mutex()

        job = scope.launch {
            for (url in RELAYS) {
                val client = WebSocketClient(url, scope)
                clients.add(client)
                launch {
                    client.messages.collect { raw ->
                        val listing = parseListing(raw, subId) ?: return@collect
                        if (listing.pubkey in blocked) return@collect
                        val address = "${listing.kind}:${listing.pubkey}:${listing.dTag ?: listing.id}"
                        val snapshot = newestLock.withLock {
                            val existing = newest[address]
                            if (existing != null && existing.createdAt >= listing.createdAt) {
                                null
                            } else {
                                newest[address] = listing
                                newest.values.toList()
                            }
                        }
                        snapshot?.let { publish(it) }
                    }
                }
                launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            client.send("""["REQ","$subId",{"kinds":[$kinds],"limit":$LIMIT}]""")
                        }
                    }
                }
                client.connect()
            }

            delay(COLLECT_WINDOW_MS)
            _isLoading.value = false
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

    /** @return the listing in this relay message, or null if it is not one. */
    private fun parseListing(raw: String, expectedSubId: String): MarketListing? = try {
        val array = json.parseToJsonElement(raw) as? JsonArray
        if (array == null || array.size < 3 ||
            array[0].jsonPrimitive.content != "EVENT" ||
            array[1].jsonPrimitive.content != expectedSubId
        ) {
            null
        } else {
            val event = array[2].jsonObject
            MarketListing.parse(
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
        Log.w(TAG, "unparseable relay message: ${e.message}")
        null
    }
}
