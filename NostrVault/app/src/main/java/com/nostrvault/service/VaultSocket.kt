package com.nostrvault.service

import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.concurrent.ConcurrentHashMap

/**
 * Requests to this device's vault relay at [url] (the main relay, `/lists` for list history, `/private` for drafts),
 * answering the vault's NIP-42 challenge with the caller's `signAuth` (the owner).
 *
 * One socket per URL, kept open and shared by every request to it ([VaultSessionCore]): it logs in once, not once
 * per request. Each login is a signature, and with Amber or a bunker a round trip to it (the signer storm, iOS
 * #1739). The socket closes after [IDLE_CLOSE_MS] with nothing asked, and when the vault drops it; the next request
 * opens a new one and logs in again. Twin of iOS `VaultSocket.swift`.
 */
internal object VaultSocket {
    /** How long an unused socket stays open. */
    const val IDLE_CLOSE_MS = 300_000L

    private val json = Json { ignoreUnknownKeys = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sessions = ConcurrentHashMap<String, Session>()

    /** Every verified event a REQ for [filter] (JSON) returns, or null when the vault didn't finish answering. */
    suspend fun query(
        url: String,
        filter: String,
        signAuth: suspend (challenge: String) -> NostrEvent?,
        timeoutMs: Long = 10_000,
    ): List<NostrEvent>? {
        val subId = "vault-${java.util.UUID.randomUUID().toString().take(8)}"
        val outcome = session(url).perform(subId, VaultSessionCore.Kind.REQ, "[\"REQ\",\"$subId\",$filter]", signAuth, timeoutMs)
        val events = (outcome as? VaultSessionCore.Outcome.Events)?.events ?: return null
        return events.filter { HavenBridge.verifyEvent(it.toString()) }.mapNotNull(::eventOf)
    }

    /**
     * Every event for [filter] however many there are: paged newest first past the vault's answer cap ([VaultPaging]),
     * on the one session. [filter] is the JSON object's inner fields without `limit` or `until` (e.g.
     * `"authors":["…"],"kinds":[3]`). Null when a page wasn't answered.
     */
    suspend fun queryAll(
        url: String,
        filterFields: String,
        signAuth: suspend (challenge: String) -> NostrEvent?,
        timeoutMs: Long = 10_000,
    ): List<NostrEvent>? {
        val byId = LinkedHashMap<String, NostrEvent>()
        var until: Long? = null
        repeat(VaultPaging.MAX_PAGES) {
            val page = "{$filterFields,\"limit\":${VaultPaging.LIMIT}${until?.let { ",\"until\":$it" }.orEmpty()}}"
            val found = query(url, page, signAuth, timeoutMs) ?: return null
            val known = byId.keys.toSet()
            for (e in found) byId[e.id] = e
            until = VaultPaging.nextUntil(found.map { it.id to it.createdAt }, known) ?: return byId.values.toList()
        }
        return byId.values.toList()
    }

    /** Sends [event] to [url] and waits for its OK: true only when the vault accepted it or already held it. */
    suspend fun publish(
        url: String,
        event: NostrEvent,
        signAuth: suspend (challenge: String) -> NostrEvent?,
        timeoutMs: Long = 6_000,
    ): Boolean {
        val frame = "[\"EVENT\",${EventPublisher.serializeSignedEvent(event)}]"
        val outcome = session(url).perform(event.id, VaultSessionCore.Kind.EVENT, frame, signAuth, timeoutMs)
        return (outcome as? VaultSessionCore.Outcome.Accepted)?.ok == true
    }

    /** Closes every session (tests; Factory Reset relaunches the process anyway). */
    fun closeAllForTest() {
        sessions.values.forEach { it.closeNow() }
        sessions.clear()
    }

    private fun session(url: String): Session = sessions.getOrPut(url) { Session(url) }

    /** One URL's socket, driven by its [VaultSessionCore]. Every core call runs under [lock]. */
    private class Session(val url: String) {
        private val core = VaultSessionCore()
        private val lock = Mutex()
        private val waiters = HashMap<String, CompletableDeferred<VaultSessionCore.Outcome>>()
        private var client: WebSocketClient? = null
        private var jobs: List<Job> = emptyList()
        private var idleJob: Job? = null
        /** The signer of the latest request: the AUTH this session answers with. */
        private var signAuth: suspend (String) -> NostrEvent? = { null }

        suspend fun perform(
            key: String,
            kind: VaultSessionCore.Kind,
            frame: String,
            sign: suspend (String) -> NostrEvent?,
            timeoutMs: Long,
        ): VaultSessionCore.Outcome {
            val done = CompletableDeferred<VaultSessionCore.Outcome>()
            val token = lock.withLock {
                idleJob?.cancel()
                signAuth = sign
                val (token, effects) = core.submit(key, kind, frame)
                // The first submission of a key that was already out ended as failed in `effects`; this one waits.
                apply(effects)
                waiters[key] = done
                token
            }
            return withTimeoutOrNull(timeoutMs) { done.await() } ?: run {
                lock.withLock { apply(core.timedOut(key, token)) }
                if (done.isCompleted) done.await() else VaultSessionCore.Outcome.Failed
            }
        }

        /** Runs [effects]; call with [lock] held. */
        private fun apply(effects: List<VaultSessionCore.Effect>) {
            for (effect in effects) when (effect) {
                VaultSessionCore.Effect.Connect -> open()
                VaultSessionCore.Effect.Disconnect -> drop()
                is VaultSessionCore.Effect.Send -> client?.send(effect.frame)
                is VaultSessionCore.Effect.SignAuth -> {
                    val sign = signAuth
                    scope.launch {
                        val auth = runCatching { sign(effect.challenge) }.getOrNull()
                        lock.withLock {
                            apply(
                                if (auth == null) core.authUnavailable()
                                else core.authSigned(auth.id, "[\"AUTH\",${EventPublisher.serializeSignedEvent(auth)}]"),
                            )
                        }
                    }
                }
                is VaultSessionCore.Effect.Finish -> waiters.remove(effect.key)?.complete(effect.outcome)
            }
            if (core.isIdle && client != null) scheduleIdleClose()
        }

        private fun open() {
            drop()
            val c = WebSocketClient(url = url, scope = scope, autoReconnect = false)
            client = c
            var left = false
            jobs = listOf(
                // Collected before connecting: messages has no replay.
                scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    c.messages.collect { msg ->
                        val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                        val type = (arr.getOrNull(0) as? JsonPrimitive)?.contentOrNull ?: return@collect
                        lock.withLock { if (client === c) apply(core.received(type, arr)) }
                    }
                },
                scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    c.connectionState.collect { state ->
                        when (state) {
                            WebSocketClient.ConnectionState.CONNECTED -> {
                                left = true
                                lock.withLock { if (client === c) apply(core.connected()) }
                            }
                            WebSocketClient.ConnectionState.CONNECTING, WebSocketClient.ConnectionState.RECONNECTING -> left = true
                            // The first DISCONNECTED is the new client's starting state, not a drop.
                            WebSocketClient.ConnectionState.DISCONNECTED -> if (left) {
                                lock.withLock { if (client === c) apply(core.disconnected()) }
                            }
                        }
                    }
                },
            )
            c.connect()
        }

        private fun drop() {
            jobs.forEach { it.cancel() }
            jobs = emptyList()
            client?.disconnect()
            client = null
        }

        private fun scheduleIdleClose() {
            idleJob?.cancel()
            idleJob = scope.launch {
                delay(IDLE_CLOSE_MS)
                lock.withLock {
                    if (!core.isIdle) return@withLock
                    apply(core.disconnected())
                    drop()
                }
            }
        }

        fun closeNow() {
            idleJob?.cancel()
            drop()
            waiters.values.forEach { it.complete(VaultSessionCore.Outcome.Failed) }
            waiters.clear()
        }
    }

    private fun eventOf(obj: JsonObject): NostrEvent? = runCatching {
        NostrEvent(
            id = obj["id"]!!.jsonPrimitive.content,
            pubkey = obj["pubkey"]!!.jsonPrimitive.content,
            createdAt = obj["created_at"]!!.jsonPrimitive.longOrNull!!,
            kind = obj["kind"]!!.jsonPrimitive.content.toInt(),
            tags = obj["tags"]?.jsonArray?.map { t -> (t as JsonArray).map { it.jsonPrimitive.contentOrNull.orEmpty() } }.orEmpty(),
            content = obj["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            sig = obj["sig"]!!.jsonPrimitive.content,
        )
    }.getOrNull()
}
