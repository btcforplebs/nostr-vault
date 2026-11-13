package com.nostrvault.service.emoji

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenQuoteDecoder
import com.nostrvault.service.EmojiListParse
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Browse other people's emoji sets (kind 30030), as Amethyst does (plan §1, §4.3): by the people you follow first,
 * then everyone (limit 200, the last month), one person's sets, or a pasted `naddr`. Blocked people are left out.
 * Reads only.
 */
@Singleton
class EmojiSetBrowser @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
) {
    /** A set found, with its signed event (what Add keeps). */
    data class Found(val set: EmojiListRepository.EmojiSet, val event: NostrEvent)

    enum class Scope { FOLLOWS, EVERYONE }

    suspend fun browse(scope: Scope): List<Found> {
        val since = System.currentTimeMillis() / 1000 - MONTH_S
        val filter = when (scope) {
            Scope.FOLLOWS -> {
                val follows = feedService.followedPubkeys.value.take(MAX_AUTHORS)
                if (follows.isEmpty()) return emptyList()
                """{"kinds":[30030],"authors":${strings(follows)},"limit":$LIMIT}"""
            }
            Scope.EVERYONE -> """{"kinds":[30030],"since":$since,"limit":$LIMIT}"""
        }
        return found(query(relays(), filter))
    }

    suspend fun byAuthor(pubkey: String): List<Found> =
        found(query(relays(pubkey), """{"kinds":[30030],"authors":${strings(listOf(pubkey))},"limit":$LIMIT}"""))

    /** A pasted `naddr1…` (or `nostr:naddr1…`) for a 30030, or null when it isn't one. */
    suspend fun byNaddr(text: String): Found? {
        val naddr = text.trim().removePrefix("nostr:")
        val coord = runCatching { HavenQuoteDecoder.naddrToCoordinate(naddr) }.getOrNull() ?: return null
        if (coord.kind != 30030) return null
        val filter = """{"kinds":[30030],"authors":${strings(listOf(coord.pubkey))},"#d":${strings(listOf(coord.dTag))},"limit":5}"""
        return found(query(relays(coord.pubkey), filter)).firstOrNull()
    }

    private fun found(events: List<NostrEvent>): List<Found> {
        val blocked = configStore.config.value.blockedForActiveAccount().toSet()
        return EmojiSetPick.newestPerAddress(events)
            .filter { it.pubkey !in blocked }
            .mapNotNull { e ->
                val address = EmojiSetPick.address(e) ?: return@mapNotNull null
                EmojiListParse.set(address, e.tags).takeIf { it.emojis.isNotEmpty() }?.let { Found(it, e) }
            }
    }

    private fun relays(pubkey: String? = null): List<String> =
        ((pubkey?.let { nostrService.relayLists.value[it] }.orEmpty()) + configStore.config.value.readRelays + NostrService.PROFILE_RELAYS)
            .map { it.trim() }.filter { it.startsWith("wss://") }.distinct().take(MAX_RELAYS)

    private suspend fun query(relays: List<String>, filter: String): List<NostrEvent> {
        val out = java.util.concurrent.ConcurrentHashMap<String, NostrEvent>()
        coroutineScope {
            relays.map { url ->
                launch(Dispatchers.IO) {
                    val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
                    try {
                        withTimeoutOrNull(TIMEOUT_MS) {
                            val subId = "emojisets-${UUID.randomUUID().toString().take(6)}"
                            val done = CompletableDeferred<Unit>()
                            val collector = launch {
                                client.messages.collect { msg ->
                                    val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                                    when ((arr.getOrNull(0) as? JsonPrimitive)?.contentOrNull) {
                                        "EVENT" -> {
                                            val obj = arr.getOrNull(2) as? JsonObject ?: return@collect
                                            val ev = event(obj) ?: return@collect
                                            if (ev.kind == 30030 && HavenBridge.verifyEvent(obj.toString())) out[ev.id] = ev
                                        }
                                        "EOSE", "CLOSED" -> done.complete(Unit)
                                    }
                                }
                            }
                            val sender = launch {
                                client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                                client.send("""["REQ","$subId",$filter]""")
                            }
                            client.connect()
                            done.await()
                            collector.cancel()
                            sender.cancel()
                        }
                    } finally {
                        client.disconnect()
                    }
                }
            }.joinAll()
        }
        return out.values.toList()
    }

    private fun event(obj: JsonObject): NostrEvent? = runCatching {
        NostrEvent(
            id = obj["id"]!!.jsonPrimitive.content,
            pubkey = obj["pubkey"]!!.jsonPrimitive.content,
            createdAt = obj["created_at"]!!.jsonPrimitive.longOrNull!!,
            kind = obj["kind"]!!.jsonPrimitive.intOrNull!!,
            tags = (obj["tags"] as JsonArray).map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } },
            content = obj["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            sig = obj["sig"]!!.jsonPrimitive.content,
        )
    }.getOrNull()

    private fun strings(values: List<String>) = JsonArray(values.map(::JsonPrimitive)).toString()

    private val json = Json { ignoreUnknownKeys = true }

    private companion object {
        const val LIMIT = 200
        const val MONTH_S = 30L * 24 * 3600
        const val MAX_AUTHORS = 500
        const val MAX_RELAYS = 8
        const val TIMEOUT_MS = 8_000L
    }
}

/** Picking sets out of a relay answer. Pure, for the tests. */
object EmojiSetPick {
    /** `30030:<pubkey>:<d>` for a 30030 with a `d` tag, or null. */
    fun address(e: NostrEvent): String? {
        if (e.kind != 30030) return null
        val d = e.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
        return "30030:${e.pubkey}:$d".takeIf { EmojiListParse.setRef(it) != null }
    }

    /** One event per address, the newest; newest first. */
    fun newestPerAddress(events: List<NostrEvent>): List<NostrEvent> =
        events.filter { address(it) != null }
            .groupBy { address(it)!! }
            .map { (_, group) -> group.maxWith(compareBy<NostrEvent> { it.createdAt }.thenBy { it.id }) }
            .sortedByDescending { it.createdAt }
}
