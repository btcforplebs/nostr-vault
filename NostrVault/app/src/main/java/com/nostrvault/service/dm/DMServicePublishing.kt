package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.FIRE_AND_FORGET_FLUSH_MS
import com.nostrvault.service.DMService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    internal fun DMService.isAmberMode(): Boolean = configStore.config.value.signingMode == "amber"

    internal fun DMService.resolvePrivateKey(): String? {
        val config = configStore.config.value
        // Amber mode -- no local private key available
        if (config.signingMode == "amber") return null
        return config.ownerHexKey ?: config.ownerNcryptsec?.let { ncryptsec ->
            val password = credentialStore.getKeychainPassword(config.ownerNpub ?: return null)
                ?: return null
            NIP49Service.decrypt(ncryptsec, password)
        }
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

    internal fun DMService.fireAndForgetPublish(eventJson: String, relayUrl: String) {
        scope.launch(Dispatchers.IO) {
            try {
                val client = WebSocketClient(url = relayUrl, scope = scope)
                client.connect()
                client.send("[\"EVENT\",$eventJson]")
                delay(FIRE_AND_FORGET_FLUSH_MS)
                client.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "Fire-and-forget to $relayUrl failed: ${e.message}")
            }
        }
    }

    internal fun DMService.serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)
