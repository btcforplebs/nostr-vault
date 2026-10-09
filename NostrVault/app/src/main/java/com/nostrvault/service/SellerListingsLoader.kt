package com.nostrvault.service

import com.nostrvault.data.model.MarketListing
import com.nostrvault.data.model.MarketListingBook
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json

/**
 * One person's listings, for the Shop tab on their profile. Port of
 * SellerListingsLoader.swift: asks the marketplace relays plus the seller's
 * own write relays (NIP-65), since a seller who lists from another client may
 * only publish to their outbox. Lives in the caller's scope, so leaving the
 * profile drops the sockets.
 */
class SellerListingsLoader(
    private val scope: CoroutineScope,
    private val nostrService: NostrService,
) {
    companion object {
        private const val WINDOW_MS = 10_000L
    }

    private val json = Json { ignoreUnknownKeys = true }

    private val _listings = MutableStateFlow<List<MarketListing>>(emptyList())
    val listings: StateFlow<List<MarketListing>> = _listings.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private var clients = mutableListOf<WebSocketClient>()
    private var job: Job? = null
    private var loadedPubkey: String? = null

    fun load(pubkey: String, force: Boolean = false) {
        if (!force && loadedPubkey == pubkey) return
        cancel()
        loadedPubkey = pubkey
        _listings.value = emptyList()
        _isLoading.value = true

        val relays = (MarketplaceFeedService.RELAYS + (nostrService.outboxRelays.value[pubkey] ?: emptyList())).distinct()
        val subId = "shop-${System.currentTimeMillis().toString(36)}"
        val kinds = MarketListing.KINDS.joinToString(",")
        // Newest event per address, as in the Marketplace feed: a sold
        // re-publish hides the item rather than being ignored.
        val book = MarketListingBook()
        val lock = Mutex()

        job = scope.launch {
            for (url in relays) {
                val client = WebSocketClient(url, scope)
                clients.add(client)
                launch {
                    client.messages.collect { raw ->
                        val e = parseListingEvent(json, raw, subId) ?: return@collect
                        if (e.pubkey != pubkey) return@collect
                        val snapshot = lock.withLock {
                            if (book.insert(e.id, e.pubkey, e.kind, e.content, e.createdAt, e.tags)) book.listings else null
                        }
                        if (snapshot != null) {
                            _listings.value = snapshot
                            _isLoading.value = false
                        }
                    }
                }
                launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            client.send("""["REQ","$subId",{"kinds":[$kinds],"authors":["$pubkey"],"limit":100}]""")
                        }
                    }
                }
                client.connect()
            }
            delay(WINDOW_MS)
            _isLoading.value = false
            disconnect()
        }
    }

    fun cancel() {
        job?.cancel()
        disconnect()
    }

    private fun disconnect() {
        clients.forEach { it.disconnect() }
        clients.clear()
    }
}
