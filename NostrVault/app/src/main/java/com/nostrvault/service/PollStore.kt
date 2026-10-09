package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.NIP88Poll
import com.nostrvault.data.model.PollTally
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The votes on each poll seen this session, fetched once per poll and shared
 * by its feed card and its note detail, so scrolling back to a poll shows
 * its count at once instead of asking every relay again. Port of iOS
 * PollStore.swift.
 */
@Singleton
class PollStore @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val models = ConcurrentHashMap<String, PollModel>()

    fun model(poll: NIP88Poll.Poll): PollModel =
        models.getOrPut(poll.id) { PollModel(poll, nostrService, configStore, scope) }
}

/**
 * One poll's votes: what the relays said, plus the vote sent from here
 * until a relay echoes it back.
 */
class PollModel internal constructor(
    val poll: NIP88Poll.Poll,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val scope: CoroutineScope,
) {
    data class State(
        val tally: PollTally = PollTally(),
        val isLoading: Boolean = false,
        val isSending: Boolean = false,
        val sendError: String? = null,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val responses = ConcurrentHashMap<String, NIP88Poll.Response>()
    @Volatile private var lastLoadMs = 0L

    /**
     * The relays a poll's votes are read from and sent to: its own, this
     * device's, the feed's and the author's outbox.
     */
    private fun relays(): List<String> {
        val config = configStore.config.value
        val fallback = buildList {
            config.nostrURL?.let { add(it) }
            addAll(config.readRelays)
            addAll(nostrService.outboxRelays.value[poll.pubkey].orEmpty())
        }
        return NIP88Poll.relays(poll, fallback)
    }

    fun load(force: Boolean = false) {
        val now = System.currentTimeMillis()
        // A card coming back on screen asks again only after this long.
        if (!force && now - lastLoadMs < RELOAD_AFTER_MS) return
        lastLoadMs = now
        _state.update { it.copy(isLoading = true) }
        scope.launch {
            try {
                val found = nostrService.queryRawEvents(
                    filters = listOf(NIP88Poll.responseFilter(poll.id)),
                    relayUrls = relays(),
                    onProgress = { merge(it.mapNotNull(::verifiedResponse)) },
                )
                merge(found.mapNotNull(::verifiedResponse))
            } finally {
                _state.update { it.copy(isLoading = false) }
            }
        }
    }

    private fun merge(found: List<NIP88Poll.Response>) {
        for (r in found) responses[r.id] = r
        val next = NIP88Poll.tally(responses.values.toList(), poll)
        _state.update { if (it.tally == next) it else it.copy(tally = next) }
        val known = nostrService.profiles.value
        val missing = next.voters.filter { it !in known }
        if (missing.isNotEmpty()) nostrService.fetchMissingProfiles(missing)
    }

    /** Signs and sends a vote, and counts it straight away. */
    fun vote(optionIds: List<String>) {
        val current = _state.value
        if (current.isSending || optionIds.isEmpty() || poll.isClosed()) return
        _state.update { it.copy(isSending = true, sendError = null) }
        val relayHint = poll.relays.firstOrNull() ?: configStore.config.value.nostrURL.orEmpty()
        val tags = NIP88Poll.responseTags(poll, optionIds, relayHint)
        scope.launch {
            try {
                val event = nostrService.signEventAsync(kind = NIP88Poll.RESPONSE_KIND, content = "", tags = tags)
                    ?: throw IllegalStateException("Your signer didn't answer")
                nostrService.postEvent(event)
                // postEvent reaches this device's relay, the author's inbox
                // and Blastr; NIP-88 says votes go to the poll's own relays.
                for (relay in poll.relays.filter { it.startsWith("wss://") || it.startsWith("ws://") }.distinct()) {
                    launch { runCatching { nostrService.publishAwaitingOk(event, relay) } }
                }
                merge(listOf(NIP88Poll.Response(event.id, event.pubkey, event.kind, event.createdAt, event.tags)))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "vote not sent: ${e.message}")
                _state.update { it.copy(sendError = "Vote failed: ${e.message ?: "not signed"}") }
            } finally {
                _state.update { it.copy(isSending = false) }
            }
        }
    }

    /** A vote from a relay, only when its signature holds. */
    private fun verifiedResponse(event: JsonObject): NIP88Poll.Response? {
        val id = event["id"].string() ?: return null
        val pubkey = event["pubkey"].string() ?: return null
        val kind = (event["kind"] as? JsonPrimitive)?.intOrNull ?: return null
        val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (event["tags"] as? JsonArray)?.mapNotNull { tag ->
            (tag as? JsonArray)?.map { (it as? JsonPrimitive)?.contentOrNull.orEmpty() }
        } ?: return null
        // Already counted: a relay sent it again, or it is the vote sent from here.
        if (responses.containsKey(id)) return responses[id]
        if (!HavenBridge.verifyEvent(event.toString())) return null
        return NIP88Poll.Response(id, pubkey, kind, createdAt, tags)
    }

    private fun kotlinx.serialization.json.JsonElement?.string(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private companion object {
        const val TAG = "PollStore"
        const val RELOAD_AFTER_MS = 30_000L
    }
}
