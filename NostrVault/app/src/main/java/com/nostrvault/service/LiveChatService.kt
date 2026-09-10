package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.util.Bolt11
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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
 * NIP-53 live chat: kind 1311 messages, and the kind 9735 zap receipts that
 * appear in the same stream of talk, both addressed to a stream's
 * `30311:<host>:<d>` identifier.
 *
 * Chat for a given stream lives on whichever relays that stream's audience
 * uses, which is not the same set as this vault's feed relays — zap.stream in
 * particular carries most of it. Talking only to the local relay would show an
 * empty room for a stream with a busy one, so this connects to the streaming
 * relays for as long as the viewer is watching and disconnects when they leave.
 */
@Singleton
class LiveChatService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    companion object {
        private const val TAG = "LiveChatService"
        const val CHAT_KIND = 1311
        private const val ZAP_RECEIPT_KIND = 9735
        private const val BACKLOG = 100

        /**
         * Fallback chat relays, for a stream that names none of its own.
         *
         * Ordered by where the traffic actually was when this was measured
         * (2026-09-07, 19 live streams): nos.lol carried 86 messages across 5
         * rooms, while relay.zap.stream — the relay every implementation names
         * for this, including mynostrspace.com — served zero kind-1311 events
         * of any kind. It stays in the list because other clients publish
         * there and it may come back, but it is not the one to rely on.
         */
        val STREAMING_RELAYS = listOf(
            "wss://nos.lol",
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://relay.zap.stream",
        )
    }

    /** One chat line: a message someone typed, or a zap that landed. */
    data class ChatEntry(
        val id: String,
        val pubkey: String,
        val content: String,
        val createdAt: Long,
        /**
         * Non-null for a zap receipt. 0 means the receipt carried no readable
         * amount — a real case, since the amount lives in the embedded request
         * and not every provider copies it onto the receipt.
         */
        val zapSats: Long? = null,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    private val _messages = MutableStateFlow<List<ChatEntry>>(emptyList())
    val messages: StateFlow<List<ChatEntry>> = _messages.asStateFlow()

    private val clients = mutableListOf<WebSocketClient>()
    private var job: Job? = null
    private var address: String? = null

    /**
     * Sats from a BOLT-11 invoice's human-readable prefix.
     *
     * Needed because zap receipts mostly do not say the amount anywhere else.
     * Sampled 12 stream zap receipts off nos.lol (2026-09-07): none carried an
     * `amount` tag, 5 of the 12 had no amount in the embedded request either,
     * and all 12 carried a bolt11 whose prefix gives the number —
     * `lnbc330n…` is 330 nano-BTC, which is 33 sats.
     *
     * The parsing itself moved to [Bolt11] when the wallet needed the same
     * reading before a payment confirmation.
     */
    internal fun satsFromBolt11(invoice: String): Long? = Bolt11.satsOrNull(invoice)

    /**
     * Relays to talk to, most authoritative first: the stream's own `relays`
     * tag, then the fallback set, then this vault's feed relays.
     */
    private fun relays(stream: LiveStream): List<String> =
        (stream.chatRelays + STREAMING_RELAYS + configStore.config.value.activeFeedRelays)
            .distinct()

    fun join(stream: LiveStream) {
        if (address == stream.address && clients.isNotEmpty()) return
        leave()
        address = stream.address
        _messages.value = emptyList()

        val subId = "chat-${System.currentTimeMillis().toString(36)}"
        val seen = mutableMapOf<String, ChatEntry>()
        val seenLock = Mutex()

        job = scope.launch {
            for (url in relays(stream)) {
                val client = WebSocketClient(url, scope)
                clients.add(client)
                launch {
                    client.messages.collect { raw ->
                        val entry = parseEntry(raw, subId) ?: return@collect
                        val snapshot = seenLock.withLock {
                            if (seen.containsKey(entry.id)) null
                            else {
                                seen[entry.id] = entry
                                seen.values.sortedBy { it.createdAt }
                            }
                        }
                        snapshot?.let { _messages.value = it }
                    }
                }
                launch {
                    client.connectionState.collect { state ->
                        if (state == WebSocketClient.ConnectionState.CONNECTED) {
                            client.send(
                                """["REQ","$subId",{"kinds":[$CHAT_KIND,$ZAP_RECEIPT_KIND],""" +
                                    """"#a":["${stream.address}"],"limit":$BACKLOG}]"""
                            )
                        }
                    }
                }
                client.connect()
            }
        }
    }

    fun leave() {
        job?.cancel()
        job = null
        clients.forEach { it.disconnect() }
        clients.clear()
        address = null
    }

    /**
     * Post a chat line. The `a` tag is what makes it a message in this room
     * rather than a loose note, and it carries zap.stream as its relay hint
     * because that is where the other clients look.
     *
     * @return true when at least one relay accepted the send.
     */
    suspend fun send(stream: LiveStream, text: String): Boolean {
        val body = text.trim()
        if (body.isEmpty()) return false
        val signed = try {
            nostrService.signEventAsync(
                kind = CHAT_KIND,
                content = body,
                tags = listOf(
                    // The relay hint names where this room is, so a client
                    // that only has the message can find the rest of it.
                    listOf("a", stream.address, stream.chatRelays.firstOrNull() ?: STREAMING_RELAYS.first()),
                ),
            )
        } catch (e: Exception) {
            Log.w(TAG, "chat signing failed: ${e.message}")
            null
        } ?: return false

        val wire = """["EVENT",${eventJson(signed)}]"""
        var accepted = false
        for (client in clients) {
            if (client.send(wire)) accepted = true
        }
        return accepted
    }

    private fun eventJson(event: NostrEvent): String {
        val tags = event.tags.joinToString(",") { tag ->
            "[" + tag.joinToString(",") { "\"" + it.replace("\\", "\\\\").replace("\"", "\\\"") + "\"" } + "]"
        }
        val content = event.content
            .replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return """{"id":"${event.id}","pubkey":"${event.pubkey}","created_at":${event.createdAt},""" +
            """"kind":${event.kind},"tags":[$tags],"content":"$content","sig":"${event.sig}"}"""
    }

    private fun parseEntry(raw: String, expectedSubId: String): ChatEntry? = try {
        val array = json.parseToJsonElement(raw) as? JsonArray
        if (array == null || array.size < 3 ||
            array[0].jsonPrimitive.content != "EVENT" ||
            array[1].jsonPrimitive.content != expectedSubId
        ) {
            null
        } else {
            val event = array[2].jsonObject
            val kind = event["kind"]?.jsonPrimitive?.content?.toIntOrNull()
            val id = event["id"]?.jsonPrimitive?.content
            val pubkey = event["pubkey"]?.jsonPrimitive?.content
            val createdAt = event["created_at"]?.jsonPrimitive?.content?.toLongOrNull()
            if (id == null || pubkey == null || createdAt == null) {
                null
            } else {
                val tags = event["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
                    ?: emptyList()
                when (kind) {
                    CHAT_KIND -> ChatEntry(
                        id = id,
                        pubkey = pubkey,
                        content = event["content"]?.jsonPrimitive?.content.orEmpty(),
                        createdAt = createdAt,
                    )
                    ZAP_RECEIPT_KIND -> {
                        // The receipt is signed by the provider, so the zapper
                        // and the message are in the embedded request, not on
                        // the receipt. Fall back to the receipt's own author
                        // rather than dropping a zap we cannot fully read.
                        val request = tags.firstOrNull { it.size >= 2 && it[0] == "description" }
                            ?.get(1)
                            ?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }
                        val requestTags = request?.get("tags")?.jsonArray
                            ?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
                            ?: emptyList()
                        // Rung order: the request's amount tag, then the
                        // receipt's, then the invoice itself. The invoice is
                        // the one that actually answers most of the time.
                        val sats = (requestTags + tags)
                            .firstOrNull { it.size >= 2 && it[0] == "amount" }
                            ?.get(1)?.toLongOrNull()
                            ?.takeIf { it > 0 }
                            ?.let { it / 1000 }
                            ?: tags.firstOrNull { it.size >= 2 && it[0] == "bolt11" }
                                ?.get(1)
                                ?.let { satsFromBolt11(it) }
                        ChatEntry(
                            id = id,
                            pubkey = request?.get("pubkey")?.jsonPrimitive?.content ?: pubkey,
                            content = request?.get("content")?.jsonPrimitive?.content.orEmpty(),
                            createdAt = createdAt,
                            // 0 means "this receipt did not say", not "zero
                            // sats". Showing a 0 next to a bolt states an
                            // amount that was never in the event; the UI shows
                            // the bolt alone instead.
                            zapSats = sats ?: 0L,
                        )
                    }
                    else -> null
                }
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "unparseable chat message: ${e.message}")
        null
    }
}
