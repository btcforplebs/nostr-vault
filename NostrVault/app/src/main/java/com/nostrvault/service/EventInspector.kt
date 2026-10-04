package com.nostrvault.service

import com.nostrvault.data.remote.RelayConnection
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID

/** Whether an event's id and signature check out ([HavenBridge.verifyEvent]). */
enum class SignatureCheck { VALID, INVALID, UNKNOWN }

/** What one relay said when asked for the event by id. */
sealed interface RelayPresence {
    data object Checking : RelayPresence
    data object Found : RelayPresence
    data object NotFound : RelayPresence
    data class Failed(val reason: String) : RelayPresence
}

/**
 * The data behind the Event Info sheet (port of iOS EventInspector): finds the
 * full signed event, checks its signature, asks each relay whether it has the
 * event ("seen on"), and re-broadcasts to the relays the person picks, waiting
 * for each relay's OK so "Sent" means the relay took it.
 *
 * Runs in [scope]; cancel the scope (leave the sheet) to drop every socket.
 */
class EventInspector(
    private val eventId: String,
    private val config: HavenConfig,
    private val scope: CoroutineScope,
    cachedEventJson: String? = null,
    private val connectionFactory: (String) -> RelayConnection = { url ->
        WebSocketClient(url = url, scope = scope, trustLocalhost = isLocalhost(url), autoReconnect = false)
    },
    private val verify: (String) -> Boolean = HavenBridge::verifyEvent,
    private val lookupTimeoutMs: Long = 6_000,
    private val publishTimeoutMs: Long = 10_000,
) {
    private val _event = MutableStateFlow<String?>(null)
    /** The full signed event JSON (with sig) once found. */
    val event: StateFlow<String?> = _event.asStateFlow()

    private val _isFetching = MutableStateFlow(false)
    val isFetching: StateFlow<Boolean> = _isFetching.asStateFlow()

    private val _signature = MutableStateFlow(SignatureCheck.UNKNOWN)
    val signature: StateFlow<SignatureCheck> = _signature.asStateFlow()

    private val _relays = MutableStateFlow<List<String>>(emptyList())
    /** Relays asked, in display order: this device's relay (outbox, then inbox),
     *  your feed relays, your blastr relays. No duplicates. */
    val relays: StateFlow<List<String>> = _relays.asStateFlow()

    private val _presence = MutableStateFlow<Map<String, RelayPresence>>(emptyMap())
    val presence: StateFlow<Map<String, RelayPresence>> = _presence.asStateFlow()

    private var started = false

    init {
        cachedEventJson?.let { adopt(it) }
    }

    /** Where Re-Broadcast sends by default: the blastr relays, as before. */
    val defaultBroadcastRelays: List<String> get() = config.activeBlastrRelays

    /** "This device" for the local relay's paths, the bare host for the rest. */
    fun label(relay: String): String = when (relay) {
        config.nostrURL -> "This device"
        config.localInboxURL -> "This device (inbox)"
        else -> relay.removePrefix("wss://").removePrefix("ws://").trimEnd('/')
    }

    /** Starts the lookup. Safe to call again; it runs once. */
    fun start() {
        if (started) return
        started = true
        val ordered = buildList {
            config.nostrURL?.let(::add)
            config.localInboxURL?.let(::add)
            addAll(config.activeFeedRelays)
            addAll(defaultBroadcastRelays)
        }.filter { it.isNotBlank() }.distinct()
        _relays.value = ordered
        _presence.value = ordered.associateWith { RelayPresence.Checking }
        _isFetching.value = _event.value == null
        ordered.forEach { relay -> scope.launch { lookup(relay) } }
    }

    /**
     * Sends the full signed event to [targets]. [onResult] gets each relay's
     * answer: (relay, accepted, the relay's own message, "timeout" or
     * "connection failed"). A relay that accepts it now counts as seen on.
     */
    fun broadcast(targets: List<String>, onResult: (String, Boolean, String) -> Unit) {
        val json = _event.value ?: return
        targets.forEach { relay ->
            scope.launch {
                val (ok, message) = publish(relay, json)
                if (ok) {
                    _relays.update { if (relay in it) it else it + relay }
                    _presence.update { it + (relay to RelayPresence.Found) }
                }
                onResult(relay, ok, message)
            }
        }
    }

    // MARK: - Private

    private suspend fun lookup(relay: String) {
        val result = if (!isUsableRelay(relay)) {
            RelayPresence.Failed("bad relay address")
        } else {
            val subId = "inspect-${UUID.randomUUID().toString().take(8)}"
            val req = """["REQ","$subId",{"ids":["$eventId"],"limit":1}]"""
            exchange(relay, req, lookupTimeoutMs, onDrop = RelayPresence.Failed("connection failed")) {
                lookupReply(it, subId)
            } ?: RelayPresence.Failed("timeout")
        }
        _presence.update { it + (relay to result) }
        if (_presence.value.values.none { it == RelayPresence.Checking }) _isFetching.value = false
    }

    private suspend fun publish(relay: String, eventJson: String): Pair<Boolean, String> {
        if (!isUsableRelay(relay)) return false to "bad relay address"
        return exchange(relay, """["EVENT",$eventJson]""", publishTimeoutMs, onDrop = false to "connection failed") {
            okReply(it)
        } ?: (false to "timeout")
    }

    /**
     * Opens one socket to [relay], sends [frame], and returns the first
     * answer [read] recognises; a socket that drops first yields [onDrop].
     * Null on timeout.
     */
    private suspend fun <T : Any> exchange(
        relay: String,
        frame: String,
        timeoutMs: Long,
        onDrop: T,
        read: (String) -> T?,
    ): T? {
        val conn = connectionFactory(relay)
        val answer = CompletableDeferred<T>()
        // Listen before connecting; the flows do not replay.
        val listener = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            conn.messages.collect { msg -> read(msg)?.let { answer.complete(it) } }
        }
        val watcher = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            var dialed = false
            conn.connectionState.collect { state ->
                when (state) {
                    ConnectionState.CONNECTING, ConnectionState.RECONNECTING -> dialed = true
                    ConnectionState.CONNECTED -> { dialed = true; conn.send(frame) }
                    ConnectionState.DISCONNECTED -> if (dialed) answer.complete(onDrop)
                }
            }
        }
        return try {
            conn.connect()
            withTimeoutOrNull(timeoutMs) { answer.await() }
        } finally {
            listener.cancel()
            watcher.cancel()
            conn.disconnect()
        }
    }

    private fun lookupReply(message: String, subId: String): RelayPresence? {
        val parsed = runCatching { Json.parseToJsonElement(message).jsonArray }.getOrNull() ?: return null
        if (parsed.size < 2 || parsed[1].jsonPrimitive.contentOrNull != subId) return null
        return when (parsed[0].jsonPrimitive.contentOrNull) {
            "EVENT" -> {
                val ev = parsed.getOrNull(2) as? JsonObject ?: return null
                if (ev["id"]?.jsonPrimitive?.contentOrNull != eventId) return null
                val raw = ev.toString()
                // A relay can send anything under any id; only a copy that
                // verifies counts as having the event.
                if (verify(raw)) {
                    if (_event.value == null || _signature.value != SignatureCheck.VALID) adopt(raw)
                    RelayPresence.Found
                } else {
                    RelayPresence.Failed("sent a copy that fails the signature check")
                }
            }
            "EOSE" -> RelayPresence.NotFound
            "CLOSED" -> RelayPresence.Failed(
                parsed.getOrNull(2)?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() } ?: "refused the request"
            )
            else -> null
        }
    }

    /** `["OK", <eventId>, <accepted>, <message>]` for this event, else null. */
    private fun okReply(message: String): Pair<Boolean, String>? {
        val parsed = runCatching { Json.parseToJsonElement(message).jsonArray }.getOrNull() ?: return null
        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "OK") return null
        if (parsed[1].jsonPrimitive.contentOrNull != eventId) return null
        val accepted = parsed[2].jsonPrimitive.booleanOrNull ?: false
        return accepted to (parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: "")
    }

    private fun adopt(raw: String) {
        val obj = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return
        _event.value = raw
        _signature.value = when {
            obj["sig"]?.jsonPrimitive?.contentOrNull.isNullOrEmpty() -> SignatureCheck.UNKNOWN
            verify(raw) -> SignatureCheck.VALID
            else -> SignatureCheck.INVALID
        }
        _isFetching.value = false
    }

    companion object {
        fun isLocalhost(url: String): Boolean {
            val host = url.substringAfter("://").substringBefore('/').substringBefore(':')
            return host == "127.0.0.1" || host == "localhost"
        }

        /** wss:// anywhere; plain ws:// only to this device's own relay. */
        fun isUsableRelay(url: String): Boolean =
            !url.contains(' ') && (url.startsWith("wss://") || (url.startsWith("ws://") && isLocalhost(url)))
    }
}
