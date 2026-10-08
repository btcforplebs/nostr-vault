package com.nostrvault.setup

import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import java.util.UUID

/**
 * Asks one relay for one of [pubkey]'s notes and times the answer, for the
 * relay check ([RelayCheck]). One relay per call so each gets its own clock.
 * Same as iOS `RelayCheckProbe`; socket pattern as
 * `NostrService.lookupNewestReplaceable`.
 */
object RelayCheckProbe {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun check(
        url: String,
        pubkey: String,
        timeoutMs: Long = (RelayCheck.TIMEOUT_SECONDS * 1000).toLong(),
    ): RelayCheck.Result = withContext(Dispatchers.IO) {
        coroutineScope {
            val client = WebSocketClient(url = url, scope = this, autoReconnect = false)
            val started = System.nanoTime()
            val subId = "check-${UUID.randomUUID().toString().take(6)}"
            val outcome = CompletableDeferred<RelayCheck.Result>()
            var hasNotes = false
            val collector = launch {
                client.messages.collect { msg ->
                    // A relay can send anything; a malformed frame is ignored, never thrown.
                    val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                    fun str(i: Int) = (arr.getOrNull(i) as? JsonPrimitive)?.takeIf { it.isString }?.content
                    if (str(1) != subId) return@collect
                    when (str(0)) {
                        "EVENT" -> hasNotes = true
                        "EOSE" -> outcome.complete(
                            RelayCheck.Result.answeredAfter((System.nanoTime() - started) / 1e9, hasNotes),
                        )
                        "CLOSED" -> outcome.complete(
                            RelayCheck.closedResult(str(2)),
                        )
                    }
                }
            }
            val sender = launch {
                client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                client.send("""["REQ","$subId",{"kinds":[1],"authors":["$pubkey"],"limit":1}]""")
            }
            try {
                client.connect()
                withTimeoutOrNull(timeoutMs) { outcome.await() } ?: RelayCheck.Result.NotAnswering
            } finally {
                collector.cancel()
                sender.cancel()
                client.disconnect()
            }
        }
    }
}
