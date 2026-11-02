package com.nostrvault.service

import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.concurrent.atomic.AtomicReference

/**
 * One short request to this device's vault relay at [url] (the main relay, or
 * `/lists` for list history), answering a NIP-42 challenge with [signAuth] as
 * DraftService does for /private. Twin of iOS `VaultSocket.swift`.
 */
internal object VaultSocket {
    private val json = Json { ignoreUnknownKeys = true }

    /** Every verified event a REQ for [filter] (JSON) returns, or null when the vault didn't finish answering. */
    suspend fun query(
        url: String,
        filter: String,
        signAuth: suspend (challenge: String) -> NostrEvent?,
        timeoutMs: Long = 10_000,
    ): List<NostrEvent>? = coroutineScope {
        val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
        val found = java.util.Collections.synchronizedList(mutableListOf<NostrEvent>())
        val subId = "vault-${java.util.UUID.randomUUID().toString().take(8)}"
        val req = "[\"REQ\",\"$subId\",$filter]"
        try {
            withTimeoutOrNull(timeoutMs) {
                val done = CompletableDeferred<Boolean>()
                val authId = AtomicReference<String?>(null)
                val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                    client.messages.collect { msg ->
                        val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                        when (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull) {
                            "AUTH" -> {
                                val challenge = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull ?: return@collect
                                launch { authenticate(client, challenge, authId, signAuth) }
                            }
                            // Ask again once the relay has taken the AUTH.
                            "OK" -> if (authId.get() != null && arr.getOrNull(1)?.jsonPrimitive?.contentOrNull == authId.get()) {
                                client.send(req)
                            }
                            "EVENT" -> {
                                if (arr.getOrNull(1)?.jsonPrimitive?.contentOrNull != subId) return@collect
                                val obj = arr.getOrNull(2)?.jsonObject ?: return@collect
                                if (!HavenBridge.verifyEvent(obj.toString())) return@collect
                                eventOf(obj)?.let { found.add(it) }
                            }
                            "EOSE" -> if (arr.getOrNull(1)?.jsonPrimitive?.contentOrNull == subId) done.complete(true)
                            // "auth-required:" before AUTH lands; the REQ is sent again after it.
                            "CLOSED" -> {
                                val reason = arr.getOrNull(2)?.jsonPrimitive?.contentOrNull.orEmpty()
                                if (!reason.startsWith("auth-required")) done.complete(false)
                            }
                        }
                    }
                }
                launch {
                    client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                    client.send(req)
                }
                client.connect()
                val answered = done.await()
                collector.cancel()
                if (answered) synchronized(found) { found.toList() } else null
            }
        } finally {
            client.disconnect()
        }
    }

    /** Sends [event] to [url] and waits for its OK: true only when the vault accepted it or already held it. */
    suspend fun publish(
        url: String,
        event: NostrEvent,
        signAuth: suspend (challenge: String) -> NostrEvent?,
        timeoutMs: Long = 6_000,
    ): Boolean = coroutineScope {
        val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
        val message = "[\"EVENT\",${EventPublisher.serializeSignedEvent(event)}]"
        try {
            withTimeoutOrNull(timeoutMs) {
                val done = CompletableDeferred<Boolean>()
                val authId = AtomicReference<String?>(null)
                val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                    client.messages.collect { msg ->
                        val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                        when (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull) {
                            "AUTH" -> {
                                val challenge = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull ?: return@collect
                                launch { authenticate(client, challenge, authId, signAuth) }
                            }
                            "OK" -> {
                                val id = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull
                                if (id != null && id == authId.get()) {
                                    client.send(message)
                                } else if (id == event.id) {
                                    val accepted = arr.getOrNull(2)?.jsonPrimitive?.contentOrNull == "true"
                                    val reason = arr.getOrNull(3)?.jsonPrimitive?.contentOrNull.orEmpty()
                                    if (accepted || reason.startsWith("duplicate")) done.complete(true)
                                    else if (!reason.startsWith("auth-required")) done.complete(false)
                                }
                            }
                        }
                    }
                }
                launch {
                    client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                    client.send(message)
                }
                client.connect()
                val ok = done.await()
                collector.cancel()
                ok
            } ?: false
        } finally {
            client.disconnect()
        }
    }

    private suspend fun authenticate(
        client: WebSocketClient,
        challenge: String,
        authId: AtomicReference<String?>,
        signAuth: suspend (String) -> NostrEvent?,
    ) {
        val auth = signAuth(challenge) ?: return
        authId.set(auth.id)
        client.send("[\"AUTH\",${EventPublisher.serializeSignedEvent(auth)}]")
    }

    private fun eventOf(obj: JsonObject): NostrEvent? = runCatching {
        NostrEvent(
            id = obj["id"]!!.jsonPrimitive.content,
            pubkey = obj["pubkey"]!!.jsonPrimitive.content,
            createdAt = obj["created_at"]!!.jsonPrimitive.longOrNull!!,
            kind = obj["kind"]!!.jsonPrimitive.content.toInt(),
            tags = obj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }.orEmpty(),
            content = obj["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            sig = obj["sig"]!!.jsonPrimitive.content,
        )
    }.getOrNull()
}
