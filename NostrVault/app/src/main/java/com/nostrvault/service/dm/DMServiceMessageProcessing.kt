package com.nostrvault.service

import com.nostrvault.relay.VerifiedEvents
import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.TAG

    /** The active account's blocked people, as hex pubkeys. */
    internal fun DMService.blockedHex(config: HavenConfig = configStore.config.value): Set<String> =
        config.blockedForActiveAccount().mapNotNull { nostrService.npubToHex(it) }.toSet()

    /** True when [eventId] is the copy of a DM this device just sent to itself. */
    fun DMService.isOwnSentWrap(eventId: String): Boolean = sentSelfWrapIds.contains(eventId)

    /** The counterparty and message decrypted from [eventId], if the inbox has opened it. */
    fun DMService.openedMessage(eventId: String): Pair<String, DMMessage>? =
        openedMessages[eventId]
            ?: _conversations.value.firstNotNullOfOrNull { convo ->
                convo.messages.lastOrNull { it.id == eventId }?.let { convo.id to it }
            }

    /**
     * Waits for the inbox to decrypt an event the relay has just reported. The
     * marker and this service's subscription see the same event at nearly the
     * same moment. Null when it does not open in time: another account's inbox,
     * or Amber, which only decrypts while a DM screen is open.
     */
    suspend fun DMService.awaitOpenedMessage(eventId: String, timeoutMs: Long): Pair<String, DMMessage>? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            openedMessage(eventId)?.let { return it }
            if (System.currentTimeMillis() >= deadline) return null
            delay(200)
        }
    }

    internal fun DMService.recordOpened(counterparty: String, message: DMMessage) {
        openedMessages[message.id] = counterparty to message
    }
    // ══════════════════════════════════════════════════════════════════
    // Message handling
    // ══════════════════════════════════════════════════════════════════

    internal fun DMService.handleChatRelayMessage(message: String, generation: Int) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            if (BuildConfig.DEBUG && type != "EVENT") Log.w(TAG, "DBG: /chat recv type=$type")
            when (type) {
                "AUTH" -> handleAuthChallenge(parsed, inboxClient)
                "OK" -> {
                    // Response to our NIP-42 AUTH event. The /chat relay requires
                    // AUTH *before* it will accept a REQ, so the kind-1059
                    // subscription must be sent here, once AUTH succeeds — NOT on
                    // EOSE (an EOSE only ever arrives in response to a REQ, so the
                    // old EOSE-gated subscribe never fired and no DMs loaded).
                    //
                    // Only the OK that answers our own AUTH event may do this.
                    // This used to fire on ANY successful OK, which was harmless
                    // while the socket carried nothing but our own two sent
                    // wraps — but every externally-fetched DM is now written back
                    // over this same socket (DMServiceLocalInjection), and one
                    // re-REQ per write would have the relay re-stream the whole
                    // stored backlog hundreds of times over.
                    val okId = parsed.getOrNull(1)?.jsonPrimitive?.contentOrNull
                    val success = parsed.getOrNull(2)?.jsonPrimitive?.booleanOrNull ?: false
                    val reason = parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull
                    if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /chat OK id=${okId?.take(8)} success=$success reason=$reason")
                    if (success && okId != null && okId == chatAuthEventId) sendChatNip17Req()
                }
                "CLOSED" -> {
                    // The /chat relay's RejectFilter is [MustAuth, MustBeInWotToQuery].
                    // Its Web of Trust takes ~60s to build on launch, and until then
                    // every query — even the owner's — is rejected with CLOSED. The
                    // subscription is sent once on AUTH-OK and never retried, so a
                    // cold start loses all NIP-17 (gift-wrapped) delivery until the
                    // next reconnect happens to land after WoT is ready. Re-arm the
                    // sub on a backoff so gift wraps start flowing once WoT warms up.
                    val subId = parsed.getOrNull(1)?.jsonPrimitive?.contentOrNull
                    val reason = parsed.getOrNull(2)?.jsonPrimitive?.contentOrNull
                    if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /chat CLOSED sub=$subId reason=$reason")
                    if (subId == "dm-nip17") scheduleChatResubscribe(generation)
                }
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return

                    if (kind == 1059) {
                        // NIP-17 gift-wrapped DM
                        scope.launch {
                            handleIncomingGiftWrap(eventObj, generation)
                        }
                    }
                }
                "EOSE" -> {
                    // EOSE only arrives if the REQ was ACCEPTED — WoT is ready and
                    // stored gift wraps have streamed. Stop any resubscribe backoff.
                    chatResubJob?.cancel()
                    _isLoading.value = false
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Chat relay message parse error: ${e.message}")
        }
    }

    internal fun DMService.handleNip04RelayMessage(message: String, generation: Int) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
                    if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /inbox EVENT kind=$kind")

                    if (kind == 4) {
                        scope.launch {
                            handleIncomingNIP04(eventObj, generation)
                        }
                    }
                }
                else -> if (BuildConfig.DEBUG) Log.w(TAG, "DBG: /inbox recv type=$type")
            }
        } catch (e: Exception) {
            Log.w(TAG, "NIP-04 relay message parse error: ${e.message}")
        }
    }

    /** @param fromExternal see [handleIncomingGiftWrap]. */
    internal suspend fun DMService.handleIncomingNIP04(
        eventObj: JsonObject,
        generation: Int,
        fromExternal: Boolean = false,
    ) {
        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (switchGeneration != generation) return
        if (!VerifiedEvents.verify(eventObj)) return
        if (fromExternal) injectExternalDmIntoLocalRelay(eventObj, eventId, 4)
        if (seenGiftWrapIds.contains(eventId)) { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: nip04 ${eventId.take(8)} skipped (already seen)"); return }

        // Key check before any seen claim — see handleIncomingGiftWrap.
        when (dmCryptoMode()) {
            DMCrypto.NONE -> { warnNoDmKeyOnce(); return }
            DMCrypto.AMBER -> { enqueuePendingDecrypt(eventObj, eventId); return }
            DMCrypto.BUNKER, DMCrypto.LOCAL -> Unit
        }

        if (!seenGiftWrapIds.add(eventId)) return
        if (!decryptNip04(eventObj, eventId, generation)) seenGiftWrapIds.remove(eventId)
    }

    /**
     * Decrypts a kind-4 NIP-04 DM and folds it into the conversation list.
     * Caller has already claimed [eventId] in seenGiftWrapIds.
     * @return true if processed; false ONLY if the signer was unavailable for a
     *   silent decrypt (retryable).
     */
    internal suspend fun DMService.decryptNip04(eventObj: JsonObject, eventId: String, generation: Int): Boolean {
        if (switchGeneration != generation) return true
        return withContext(Dispatchers.IO) {
            try {
                val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@withContext true
                val tags = eventObj["tags"]?.jsonArray?.map { t ->
                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList()

                val ownerHex = nostrService.activeHexPubkey
                val isFromMe = pubkey == ownerHex
                val counterparty = if (isFromMe) {
                    tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@withContext true
                } else {
                    pubkey
                }
                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: nip04 ${eventId.take(8)} fromMe=$isFromMe cp=${counterparty.take(12)} decrypting (amber=${isAmberMode()})")

                // Decrypt (Amber or local key). silentOnly for the Amber path — a
                // backlog drain must not launch an interactive Intent per message.
                val plaintext = when (dmCryptoMode()) {
                    DMCrypto.AMBER ->
                        amberSignerService.nip04Decrypt(content, counterparty, silentOnly = true)
                            ?: run {
                                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: nip04 ${eventId.take(8)} silent decrypt unavailable")
                                return@withContext false // retryable
                            }
                    DMCrypto.BUNKER ->
                        // Serialized: one bunker RPC at a time (see decryptGiftWrap).
                        bunkerDecryptMutex.withLock {
                            if (ensureDmBunkerConnected(nostrService.activeHexPubkey)) {
                                NIP46Service.nip04Decrypt(counterparty, content)
                            } else null
                        } ?: run {
                            if (BuildConfig.DEBUG) Log.w(TAG, "DBG: nip04 ${eventId.take(8)} bunker decrypt unavailable")
                            return@withContext false // retryable
                        }
                    DMCrypto.LOCAL -> {
                        val privkey = resolvePrivateKey() ?: return@withContext false
                        NIP04Service.decrypt(content, counterparty, privkey)
                            ?: run { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: nip04 ${eventId.take(8)} decrypt returned NULL"); return@withContext true }
                    }
                    DMCrypto.NONE -> return@withContext false
                }
                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: nip04 ${eventId.take(8)} decrypted len=${plaintext.length}")

                val message = DMMessage(
                    id = eventId,
                    content = plaintext,
                    timestamp = createdAt,
                    senderPubkey = pubkey,
                    isFromMe = isFromMe,
                    isNIP04 = true,
                )

                recordOpened(counterparty, message)
                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(counterparty, message)
                }
                true
            } catch (e: Exception) {
                Log.w(TAG, "NIP-04 decrypt failed: ${e.message}")
                true // bad data — don't requeue
            }
        }
    }

    /** Queue a raw inbound DM event for on-demand (Amber) decryption. */
    internal fun DMService.enqueuePendingDecrypt(eventObj: JsonObject, eventId: String) {
        if (seenGiftWrapIds.contains(eventId)) return
        if (!queuedDecryptIds.add(eventId)) return
        pendingDecryptQueue.add(eventObj)
        _pendingDecryptCount.value = pendingDecryptQueue.size
        // Survive a process death: the signer may not be reachable for hours.
        savePendingQueue()
        if (BuildConfig.DEBUG) Log.w(TAG, "DBG: queued ${eventId.take(8)} for decrypt (pending=${pendingDecryptQueue.size})")
    }
