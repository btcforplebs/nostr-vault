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
import com.nostrvault.relay.DMInbox
import com.nostrvault.service.NostrService.Companion.isLoopbackRelay

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

    /**
     * Publish an event to local relay + smart broadcast to target relays.
     * With [onBroadcastOutcome], the Blastr broadcast waits for relay `OK`s and
     * reports once: accepted when one relay takes it, refused when none does
     * after the retries (see [broadcastConfirmed]). Called on the main thread.
     */
    internal fun NostrService.postEventImpl(event: NostrEvent, onBroadcastOutcome: ((BroadcastTally.Outcome) -> Unit)? = null) {
        val eventJson = serializeEvent(event)

        // 0. The owner's home vault on the mesh, which passes it on to the
        //    regular relays too. Queued while it is out of reach.
        homeVault.offerEvent(event.id, event.pubkey, eventJson)

        // 1. Post to local relay
        scope.launch(Dispatchers.IO) {
            val localUrl = configStore.config.value.nostrURL
            if (localUrl != null) {
                val client = clients[normalizeRelayUrl(localUrl)]
                    ?: connectToRelay(localUrl, onMessage = {})
                client?.send("[\"EVENT\",$eventJson]")
            }
        }

        // 2. Smart broadcast based on event kind and target
        val toBlastr: () -> Unit = if (onBroadcastOutcome == null) {
            { broadcastRawEvent(eventJson) }
        } else {
            {
                scope.launch {
                    val outcome = broadcastConfirmed(event, configStore.config.value.activeBlastrRelays)
                    withContext(Dispatchers.Main) { onBroadcastOutcome(outcome) }
                }
            }
        }
        scope.launch(Dispatchers.IO) {
            when (event.kind) {
                0 -> toBlastr() // Profile → Blastr
                else -> {
                    // Extract target pubkey from p-tag and send to their inbox relays
                    val targetPubkey = event.tags
                        .firstOrNull { it.size >= 2 && it[0] == "p" }
                        ?.get(1)

                    if (targetPubkey != null) {
                        val targetRelays = _relayLists.value[targetPubkey]
                        if (targetRelays != null) {
                            for (relayUrl in targetRelays.filter { !it.contains("blastr") }) {
                                fireAndForgetPublish(eventJson, relayUrl)
                            }
                        }
                    }

                    // Also broadcast to Blastr for visibility
                    toBlastr()
                    // A DM relay list (10050) also goes to the DM relays it
                    // names, where senders look for it (iOS #224).
                    DMInbox.extraBroadcastRelays(event.kind, event.tags, configStore.config.value.activeBlastrRelays)
                        .filter { !isLoopbackRelay(it) }
                        .forEach { fireAndForgetPublish(eventJson, it) }
                }
            }
        }
    }

    /**
     * Also send [event] to [relayUrl], e.g. diVine's relay for a diVine, and
     * wait for its OK. Returns whether it accepted and its message; a relay
     * that never answers within [timeoutMs] counts as not accepted.
     */
    internal suspend fun NostrService.publishAwaitingOkImpl(event: NostrEvent, relayUrl: String, timeoutMs: Long = 15_000): Pair<Boolean, String> {
        if (!isValidRelayUrl(relayUrl)) return false to "bad relay address"
        val eventJson = serializeEvent(event)
        return withContext(Dispatchers.IO) {
            val client = WebSocketClient(url = relayUrl, scope = scope)
            try {
                withTimeoutOrNull(timeoutMs) {
                    coroutineScope {
                        // Listen before connecting; the flow does not replay.
                        val answer = async(start = CoroutineStart.UNDISPATCHED) {
                            client.messages.mapNotNull { okReply(it, event.id) }.first()
                        }
                        client.connect()
                        client.send("[\"EVENT\",$eventJson]")
                        answer.await()
                    }
                } ?: (false to "it didn't answer")
            } finally {
                client.disconnect()
            }
        }
    }

    /**
     * Sends [pubkey]'s newest profile (kind 0), exactly as already signed, to
     * [relayUrl] in the background. diVine's search and author pages only know
     * profiles that reach its own relay, which otherwise happens only for
     * people who have used the diVine app. Nothing is signed, so no signer prompt.
     */
    internal fun NostrService.sendProfileToImpl(pubkey: String, relayUrl: String) {
        scope.launch {
            val profile = fetchNewestReplaceable(kind = 0, pubkey = pubkey, alsoAsk = emptyList()) ?: return@launch
            publishFireAndForget(profile, listOf(relayUrl))
        }
    }

    /**
     * Also send [event] to [relays] without waiting for their answers, e.g. the
     * relays a poll names for its votes (iOS broadcastRawEvent extraRelays).
     */
    internal fun NostrService.publishFireAndForgetImpl(event: NostrEvent, relays: List<String>) {
        val eventJson = serializeEvent(event)
        relays.filter { isValidRelayUrl(it) && !isLoopbackRelay(it) }
            .forEach { fireAndForgetPublish(eventJson, it) }
    }
