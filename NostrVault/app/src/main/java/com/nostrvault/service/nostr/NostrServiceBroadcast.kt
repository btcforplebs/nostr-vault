package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.*
import kotlin.concurrent.withLock
import com.nostrvault.service.NostrService.Companion.TAG

    /**
     * Sends [event] to [relays] and reports a single outcome. When every relay
     * refuses or times out it tries again, a little later each time, before
     * giving up: a slow relay shouldn't read as a failed post.
     */
    internal suspend fun NostrService.broadcastConfirmed(event: NostrEvent, relays: List<String>): BroadcastTally.Outcome {
        val targets = relays.filter { isValidRelayUrl(it) }
        for (attempt in 0 until 3) {
            if (attempt > 0) delay(if (attempt == 1) 3_000L else 8_000L)
            if (broadcastOnceConfirmed(event, targets) == BroadcastTally.Outcome.ACCEPTED) {
                return BroadcastTally.Outcome.ACCEPTED
            }
        }
        return BroadcastTally.Outcome.REFUSED
    }

    /**
     * One pass over [relays]. Returns as soon as the outcome is decided; the
     * sends to slower relays keep going in [scope] so they still get the post.
     */
    private suspend fun NostrService.broadcastOnceConfirmed(event: NostrEvent, relays: List<String>): BroadcastTally.Outcome {
        val tally = BroadcastTally(relays.size)
        tally.outcome?.let { return it }
        val decided = CompletableDeferred<BroadcastTally.Outcome>()
        for (relayUrl in relays) {
            scope.launch(Dispatchers.IO) {
                val (ok, message) = try {
                    publishAwaitingOk(event, relayUrl, timeoutMs = 10_000)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    false to "connection failed"
                }
                tally.record(relayUrl, ok, message)?.let { decided.complete(it) }
            }
        }
        return decided.await()
    }

    /**
     * Broadcast raw event JSON to all configured Blastr relays.
     */
    fun NostrService.broadcastRawEvent(
        eventJson: String,
        onRelayResult: ((String, Boolean) -> Unit)? = null,
    ) {
        val blastrRelays = configStore.config.value.activeBlastrRelays
        for (relayUrl in blastrRelays) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                tempClientSemaphore.withPermit {
                    try {
                        val client = WebSocketClient(url = relayUrl, scope = scope)
                        tempClientsLock.withLock { temporaryClients.add(client) }

                        client.connect()
                        client.send("[\"EVENT\",$eventJson]")
                        onRelayResult?.invoke(relayUrl, true)

                        delay(300) // Allow flush
                        client.disconnect()
                        tempClientsLock.withLock { temporaryClients.remove(client) }
                    } catch (e: Exception) {
                        Log.w(TAG, "Broadcast to $relayUrl failed: ${e.message}")
                        onRelayResult?.invoke(relayUrl, false)
                    }
                }
            }
        }
    }

    /** `["OK", <eventId>, <accepted>, <message>]` for [eventId], else null. */
    internal fun NostrService.okReply(message: String, eventId: String): Pair<Boolean, String>? = runCatching {
        val parsed = Json.parseToJsonElement(message).jsonArray
        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "OK") return@runCatching null
        if (parsed[1].jsonPrimitive.contentOrNull != eventId) return@runCatching null
        val accepted = parsed[2].jsonPrimitive.booleanOrNull ?: false
        accepted to (parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: "")
    }.getOrNull()

    internal fun NostrService.fireAndForgetPublish(eventJson: String, relayUrl: String) {
        if (!isValidRelayUrl(relayUrl)) return
        scope.launch(Dispatchers.IO) {
            tempClientSemaphore.withPermit {
                try {
                    val client = WebSocketClient(url = relayUrl, scope = scope)
                    tempClientsLock.withLock { temporaryClients.add(client) }
                    client.connect()
                    client.send("[\"EVENT\",$eventJson]")
                    delay(300)
                    client.disconnect()
                    tempClientsLock.withLock { temporaryClients.remove(client) }
                } catch (e: Exception) {
                    Log.w(TAG, "Fire-and-forget to $relayUrl failed: ${e.message}")
                }
            }
        }
    }
