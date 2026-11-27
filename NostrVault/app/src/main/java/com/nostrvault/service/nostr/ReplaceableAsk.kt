package com.nostrvault.service

import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** One relay's answer to [askReplaceable]: [answered] sent its EOSE, [reached] connected. */
internal class RelayAsk(val answered: Boolean, val reached: Boolean)

/**
 * Asks [client]'s relay for the newest [kind] by [pubkey] (with [dTag]), handing each EVENT's object to [onEvent],
 * until its EOSE, a CLOSED, the socket going, or [timeoutMs]. Disconnects [client] when done.
 */
internal suspend fun askReplaceable(
    client: WebSocketClient,
    json: Json,
    kind: Int,
    pubkey: String,
    dTag: String?,
    timeoutMs: Long,
    onEvent: (JsonObject) -> Unit,
): RelayAsk = coroutineScope {
    val answered = AtomicBoolean(false)
    val reached = AtomicBoolean(false)
    try {
        withTimeoutOrNull(timeoutMs) {
            val subId = "dmlist-${UUID.randomUUID().toString().take(6)}"
            val done = CompletableDeferred<Unit>()
            val collector = launch {
                client.messages.collect { msg ->
                    val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                    when ((arr.getOrNull(0) as? JsonPrimitive)?.contentOrNull) {
                        "EVENT" -> (arr.getOrNull(2) as? JsonObject)?.let(onEvent)
                        "EOSE" -> {
                            val ours = (arr.getOrNull(1) as? JsonPrimitive)?.contentOrNull == subId
                            if (done.complete(Unit) && ours) answered.set(true)
                        }
                        "CLOSED" -> done.complete(Unit)
                    }
                }
            }
            val sender = launch {
                client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                reached.set(true)
                val dFilter = dTag?.let { ""","#d":[${JsonPrimitive(it)}]""" } ?: ""
                client.send("""["REQ","$subId",{"kinds":[$kind],"authors":["$pubkey"]$dFilter,"limit":1}]""")
            }
            client.connect()
            // A relay that failed, closed or was never dialled (blocked, held)
            // is done now, not at the timeout; it still doesn't count as answered.
            val gone = launch {
                client.connectionState.first { it == WebSocketClient.ConnectionState.DISCONNECTED }
                // An EOSE sent just before the close may still sit in [messages].
                delay(GONE_DRAIN_MS)
                done.complete(Unit)
            }
            done.await()
            collector.cancel()
            sender.cancel()
            gone.cancel()
        }
    } finally {
        client.disconnect()
    }
    RelayAsk(answered.get(), reached.get())
}
