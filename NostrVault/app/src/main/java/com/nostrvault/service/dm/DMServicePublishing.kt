package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    /**
     * Whether the ACTIVE account signs through Amber. Was the owner's global
     * mode, so a second account on Amber decrypted nothing and an Amber owner
     * with a local second account queued DMs it could have read at once.
     */
    internal fun DMService.isAmberMode(): Boolean =
        configStore.config.value.activeSigningMode() == "amber"

    /**
     * The ACTIVE account's secret key, or null when the key is not on this
     * device (Amber, a bunker, or watch-only). This used to resolve the
     * OWNER's key whatever account was active, so a second account's DMs were
     * sealed with the owner's key: the seal's author then contradicted the
     * rumor's, every correct client (this one included — see
     * [NIP17Service.isAuthoredBySealer]) dropped the message, and the wrap tied
     * the second account to the owner key.
     */
    internal fun DMService.resolvePrivateKey(): String? {
        val mode = configStore.config.value.activeSigningMode()
        if (mode == "amber" || mode == "nip46") return null
        return nostrService.resolveSecretKey(forceOwner = false)
    }

    internal suspend fun DMService.fetchRecipientDMRelays(pubkey: String): List<String> {
        // Someone else's advertised 127.0.0.1 is OUR machine, so publishing
        // there drops their DM into our own relay — the write succeeds and the
        // message is lost. Older builds advertised exactly that, so such entries
        // are out there and have to be dropped. Filtering can empty a list;
        // falling through to the next source is what stops that from silently
        // delivering nowhere.
        fun reachable(relays: List<String>?): List<String> =
            relays.orEmpty().filter { !NostrService.isLoopbackRelay(it) }

        reachable(nostrService.dmRelayLists.value[pubkey]).let { if (it.isNotEmpty()) return it }

        // No DM relay list known yet: fetch and wait for it. A general
        // (kind 10002) list is only the fallback for someone who published no
        // DM list, so it must not win just because it was already cached.
        nostrService.fetchRelayList(pubkey)
        delay(4_000)

        reachable(nostrService.dmRelayLists.value[pubkey]).let { if (it.isNotEmpty()) return it }
        reachable(nostrService.relayLists.value[pubkey]).let { if (it.isNotEmpty()) return it.take(3) }
        return reachable(configStore.config.value.activeBlastrRelays).take(3)
    }

    /**
     * This account's DM inbox list, minus loopback. For the owner that is the
     * published list — the Mac relay's inbox first. Other accounts use the
     * plain DM relays: the owner's Haven inbox only takes DMs for the owner.
     */
    internal fun DMService.ownDMInboxRelays(accountHex: String): List<String> {
        val config = configStore.config.value
        val list = if (accountHex == nostrService.ownerHexPubkey) config.dmInboxRelays else config.dmRelays
        return list.filter { !NostrService.isLoopbackRelay(it) }
    }

    /**
     * Publishes to a relay that may require NIP-42 AUTH before it accepts a
     * write. A Haven inbox (the Mac relay) rejects with "auth-required" until
     * the sender authenticates, which the plain fire-and-forget publish never
     * noticed. An auth-required rejection is answered with AUTH signed by the
     * sending account — never the owner on another account's behalf, which
     * would tie the accounts together — and, once the relay accepts the AUTH,
     * the event is sent again. (Relays handle each message concurrently, so
     * resending before the AUTH is accepted can lose the race.)
     */
    internal fun DMService.publishAuthenticated(eventJson: String, relayUrl: String, senderHex: String) {
        val eventId = runCatching { json.parseToJsonElement(eventJson).jsonObject["id"]?.jsonPrimitive?.contentOrNull }.getOrNull() ?: return
        scope.launch(Dispatchers.IO) {
            val client = WebSocketClient(url = relayUrl, scope = this, autoReconnect = false)
            val result = try {
                withTimeoutOrNull(15_000) {
                    val outcome = CompletableDeferred<String>()
                    var challenge: String? = null
                    var authId: String? = null
                    val collector = launch {
                        client.messages.collect { msg ->
                            val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull() ?: return@collect
                            when (arr.getOrNull(0)?.jsonPrimitive?.contentOrNull) {
                                "AUTH" -> challenge = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull
                                "OK" -> {
                                    val id = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull
                                    val ok = arr.getOrNull(2)?.jsonPrimitive?.booleanOrNull ?: false
                                    val note = arr.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: ""
                                    if (id != null && id == authId) {
                                        if (ok) client.send("[\"EVENT\",$eventJson]") else outcome.complete("AUTH rejected: $note")
                                    } else if (id == eventId) {
                                        val ch = challenge
                                        when {
                                            ok || note.startsWith("duplicate") -> outcome.complete("accepted")
                                            note.startsWith("auth-required") && authId == null && ch != null -> {
                                                if (nostrService.activeHexPubkey != senderHex) {
                                                    outcome.complete("account switched before AUTH")
                                                } else {
                                                    val auth = runCatching {
                                                        nostrService.signEventAsync(
                                                            kind = 22242, content = "",
                                                            tags = listOf(listOf("relay", relayUrl), listOf("challenge", ch)),
                                                        )
                                                    }.getOrNull()
                                                    if (auth == null) {
                                                        outcome.complete("could not sign AUTH")
                                                    } else {
                                                        authId = auth.id
                                                        client.send("[\"AUTH\",${serializeEvent(auth)}]")
                                                    }
                                                }
                                            }
                                            else -> outcome.complete("rejected: $note")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    launch {
                        client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                        client.send("[\"EVENT\",$eventJson]")
                    }
                    client.connect()
                    val r = outcome.await()
                    collector.cancel()
                    r
                } ?: "timed out"
            } catch (e: Exception) {
                "failed: ${e.message}"
            } finally {
                client.disconnect()
            }
            Log.d(TAG, "DM wrap ${eventId.take(8)} -> $relayUrl: $result")
        }
    }

    /**
     * Sends [eventJson] to [relayUrl] without the caller waiting. The socket
     * stays open until the relay's OK (10 s cap): nos.lol, primal, nostr.mom
     * and relay.nostr.net drop an event whose socket closes right after it
     * (measured 2026-10-25: 0 of 4 kept it, 4 of 4 when the OK was awaited).
     */
    internal fun DMService.fireAndForgetPublish(eventJson: String, relayUrl: String) {
        val eventId = runCatching { json.parseToJsonElement(eventJson).jsonObject["id"]?.jsonPrimitive?.contentOrNull }.getOrNull() ?: return
        scope.launch(Dispatchers.IO) {
            val client = WebSocketClient(url = relayUrl, scope = this, autoReconnect = false)
            val result = try {
                withTimeoutOrNull(10_000) {
                    coroutineScope {
                        // Listen before connecting; the flow does not replay.
                        val answer = async(start = CoroutineStart.UNDISPATCHED) {
                            client.messages.mapNotNull { msg ->
                                val arr = runCatching { json.parseToJsonElement(msg).jsonArray }.getOrNull()
                                if (arr?.getOrNull(0)?.jsonPrimitive?.contentOrNull == "OK" &&
                                    arr.getOrNull(1)?.jsonPrimitive?.contentOrNull == eventId
                                ) {
                                    val ok = arr.getOrNull(2)?.jsonPrimitive?.booleanOrNull ?: false
                                    if (ok) "accepted" else "rejected: ${arr.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: ""}"
                                } else null
                            }.first()
                        }
                        launch {
                            client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
                            client.send("[\"EVENT\",$eventJson]")
                        }
                        client.connect()
                        answer.await()
                    }
                } ?: "timed out"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "failed: ${e.message}"
            } finally {
                client.disconnect()
            }
            if (result != "accepted") Log.w(TAG, "DM send ${eventId.take(8)} -> $relayUrl: $result")
        }
    }

    internal fun DMService.serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)
