package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.LiveStatusBook
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Which accounts are live right now (NIP-53 kind 30311), for the red ring on
 * their profile picture.
 *
 * Avatars ask by appearing: [watch] collects the pubkeys on screen and, after
 * a short pause, sends one REQ for the ones not asked about in the last few
 * minutes — by author and by `p` tag, since services like zap.stream publish
 * streams under their own key with the streamer as Host. Like the Live tab,
 * nothing is saved to the device's relay; a stream only matters while it runs.
 * iOS: LiveStatusService.
 */
@Singleton
class LiveStatusService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "LiveStatusService"
        /** Pause before a batch goes out, so a screenful of avatars is one REQ. */
        private const val BATCH_DELAY_MS = 600L
        /** Relays cap filter sizes; larger batches are split. */
        private const val MAX_PER_FILTER = 150
        /** A lookup is closed after this, answered or not. */
        private const val LOOKUP_TIMEOUT_MS = 10_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()

    private val book = LiveStatusBook()
    private val pending = mutableSetOf<String>()
    private var flush: Job? = null
    private var account: String? = null

    /**
     * Pubkeys hosting a live, playable stream. Republished only when the set
     * changes, so avatars do not redraw for every event that arrives.
     */
    private val _liveHosts = MutableStateFlow<Set<String>>(emptySet())
    val liveHosts: StateFlow<Set<String>> = _liveHosts.asStateFlow()

    /** The stream [pubkey] is hosting right now, if any. */
    fun stream(hostedBy: String): LiveStream? = synchronized(lock) {
        if (hostedBy !in _liveHosts.value) null else book.liveStream(hostedBy, nowSeconds())
    }

    /** An avatar for [pubkey] is on screen. */
    fun watch(pubkey: String) {
        if (pubkey.length != 64) return
        synchronized(lock) {
            resetIfAccountChanged()
            pending.add(pubkey)
            if (flush?.isActive == true) return
            flush = scope.launch {
                delay(BATCH_DELAY_MS)
                flush()
            }
        }
    }

    private fun nowSeconds() = System.currentTimeMillis() / 1000

    private fun resetIfAccountChanged() {
        val current = configStore.activeAccountHexPubkey.value
        if (current == account) return
        account = current
        book.reset()
        _liveHosts.value = emptySet()
    }

    private fun flush() {
        val due = synchronized(lock) {
            val due = book.takeDue(pending.toSet(), System.currentTimeMillis())
            pending.clear()
            due
        }
        // A stream can end between lookups; drop rings that have gone stale.
        republish()
        if (due.isEmpty()) return

        val filters = due.chunked(MAX_PER_FILTER).joinToString(",") { chunk ->
            val list = chunk.joinToString(",") { "\"$it\"" }
            """{"kinds":[${LiveStream.KIND}],"authors":[$list],"limit":50},""" +
                """{"kinds":[${LiveStream.KIND}],"#p":[$list],"limit":50}"""
        }
        val subId = "ring-${System.currentTimeMillis().toString(36)}"
        val req = """["REQ","$subId",$filters]"""

        scope.launch {
            val clients = configStore.config.value.activeFeedRelays.map { url ->
                WebSocketClient(url, this, autoReconnect = false).also { client ->
                    launch { client.messages.collect { handle(it, subId) } }
                    launch {
                        client.connectionState.collect { state ->
                            if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(req)
                        }
                    }
                    client.connect()
                }
            }
            delay(LOOKUP_TIMEOUT_MS)
            clients.forEach { it.disconnect() }
            cancel() // the collectors with it
        }
    }

    private fun handle(raw: String, subId: String) {
        val stream = try {
            val array = json.parseToJsonElement(raw) as? JsonArray ?: return
            if (array.size < 3 || array[0].jsonPrimitive.content != "EVENT" ||
                array[1].jsonPrimitive.content != subId
            ) return
            val event = array[2].jsonObject
            if (event["kind"]?.jsonPrimitive?.content?.toIntOrNull() != LiveStream.KIND) return
            LiveStream.from(
                pubkey = event["pubkey"]?.jsonPrimitive?.content.orEmpty(),
                createdAt = event["created_at"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
                tags = event["tags"]?.jsonArray?.map { tag -> tag.jsonArray.map { it.jsonPrimitive.content } }
                    ?: emptyList(),
            ) ?: return
        } catch (e: Exception) {
            Log.w(TAG, "unparseable relay message: ${e.message}")
            return
        }
        if (synchronized(lock) { book.ingest(stream) }) republish()
    }

    private fun republish() {
        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        val hosts = synchronized(lock) { book.liveHosts(nowSeconds()) } - blocked
        if (hosts != _liveHosts.value) _liveHosts.value = hosts
    }
}
