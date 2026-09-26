package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.LiveStream
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
 * NIP-53 live streams (kind 30311).
 *
 * Deliberately its own service with its own short-lived connections rather
 * than another mode on the feed subscription: a live event is not a note, it
 * is a replaceable announcement whose truth expires. A stream that ended two
 * minutes ago still says `live` in whatever we cached, so this always refetches
 * rather than restoring anything.
 */
@Singleton
class LiveFeedService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "LiveFeedService"
        private const val LIMIT = 300
        /**
         * How long to hold the relay connections open for one refresh.
         *
         * 6s was too short on the phone: five sockets each have to do DNS, TLS
         * and a subscription, and the window closed with an empty list on a
         * connection that was working fine — the relays connected at t+5s and
         * were disconnected at t+6s before any of them answered.
         */
        private const val COLLECT_WINDOW_MS = 20_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    private val _streams = MutableStateFlow<List<LiveStream>>(emptyList())
    val streams: StateFlow<List<LiveStream>> = _streams.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private var clients = mutableListOf<WebSocketClient>()
    private var job: Job? = null

    fun refresh() {
        job?.cancel()
        disconnect()
        _isLoading.value = true

        val relays = configStore.config.value.activeFeedRelays
        if (relays.isEmpty()) {
            _isLoading.value = false
            return
        }

        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        val subId = "live-${System.currentTimeMillis().toString(36)}"
        // Newest announcement per address wins: 30311 is replaceable, so the
        // same stream arrives repeatedly with updated status and viewer counts,
        // and keeping the first copy would pin it to whatever it said first.
        //
        // One collector per relay writes into this concurrently. A plain
        // LinkedHashMap crashed the app with ConcurrentModificationException on
        // the first real run — one relay inserting while another's publish()
        // iterated. The mutex is what makes read-modify-write atomic; the
        // snapshot copy is what keeps the iteration off the live map.
        val newest = mutableMapOf<String, LiveStream>()
        val newestLock = Mutex()

        job = scope.launch {
            for (url in relays) {
                val client = WebSocketClient(url, scope)
                clients.add(client)
                launch {
                    client.messages.collect { raw ->
                        val stream = parseStream(raw, subId) ?: return@collect
                        if (stream.hostPubkey in blocked) return@collect
                        val snapshot = newestLock.withLock {
                            val existing = newest[stream.address]
                            if (existing != null && existing.createdAt >= stream.createdAt) {
                                null
                            } else {
                                newest[stream.address] = stream
                                newest.values.toList()
                            }
                        }
                        snapshot?.let { publish(it) }
                    }
                }
                launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            client.send("""["REQ","$subId",{"kinds":[${LiveStream.KIND}],"limit":$LIMIT}]""")
                        }
                    }
                }
                client.connect()
            }

            delay(COLLECT_WINDOW_MS)
            _isLoading.value = false
            // These connections exist to answer one question; holding them open
            // would keep five sockets alive behind a screen nobody is on.
            disconnect()
        }
    }

    fun disconnect() {
        clients.forEach { it.disconnect() }
        clients.clear()
    }

    private fun publish(values: Collection<LiveStream>) {
        val now = System.currentTimeMillis() / 1000
        _streams.value = values
            .filter { it.isPlayableLive && it.isOnAirAt(now) }
            .sortedByDescending { it.participants ?: 0 }
    }

    /** @return the stream in this relay message, or null if it is not one. */
    private fun parseStream(raw: String, expectedSubId: String): LiveStream? = try {
        val array = json.parseToJsonElement(raw) as? JsonArray
        if (array == null || array.size < 3 ||
            array[0].jsonPrimitive.content != "EVENT" ||
            array[1].jsonPrimitive.content != expectedSubId
        ) {
            null
        } else {
            val event = array[2].jsonObject
            val kind = event["kind"]?.jsonPrimitive?.content?.toIntOrNull()
            if (kind != LiveStream.KIND) {
                null
            } else {
                LiveStream.from(
                    pubkey = event["pubkey"]?.jsonPrimitive?.content.orEmpty(),
                    createdAt = event["created_at"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
                    tags = event["tags"]?.jsonArray?.map { tag ->
                        tag.jsonArray.map { it.jsonPrimitive.content }
                    } ?: emptyList(),
                )
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "unparseable relay message: ${e.message}")
        null
    }
}
