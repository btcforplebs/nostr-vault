package com.nostrvault.service

import com.nostrvault.relay.VerifiedEvents
import android.util.Log
import com.nostrvault.BuildConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.TAG

    /**
     * @param fromExternal the event came from an outside relay, so it also has
     *   to be written into this device's own relay ([injectExternalDmIntoLocalRelay]).
     *   That happens before the seen check: a DM read back from the conversation
     *   cache is already "seen", and the old order meant such a DM could never
     *   be persisted into the relay at all.
     */
    internal suspend fun DMService.handleIncomingGiftWrap(
        eventObj: JsonObject,
        generation: Int,
        fromExternal: Boolean = false,
    ) {
        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (switchGeneration != generation) return
        // Before any seen/queued claim or injection, so a forged copy carrying a
        // real event's id cannot shadow the real one. A relay can serve any event
        // under any author; NIP-04 has no MAC, so a re-IV'd copy of a real DM
        // decrypts to altered text. Only the signature ties it to its author.
        if (!VerifiedEvents.verify(eventObj)) return
        if (fromExternal) injectExternalDmIntoLocalRelay(eventObj, eventId, 1059)
        if (seenGiftWrapIds.contains(eventId)) { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} skipped (already seen)"); return }

        // The key check comes BEFORE any seen claim: marking first meant a
        // watch-only or still-locked account recorded the wrap as handled and
        // nothing reprocessed it when the key arrived in the same session.
        when (dmCryptoMode()) {
            DMCrypto.NONE -> { warnNoDmKeyOnce(); return }
            // Amber: queue instead of decrypting now (see pendingDecryptQueue).
            DMCrypto.AMBER -> { enqueuePendingDecrypt(eventObj, eventId); return }
            DMCrypto.BUNKER, DMCrypto.LOCAL -> Unit
        }

        if (!seenGiftWrapIds.add(eventId)) return
        // A retryable failure (signer unreachable) must give the id back, or a
        // reconnect that re-serves the wrap would skip it forever.
        if (!decryptGiftWrap(eventObj, eventId, generation)) seenGiftWrapIds.remove(eventId)
    }

    /**
     * Decrypts a kind-1059 gift wrap and folds it into the conversation list.
     * Caller has already claimed [eventId] in seenGiftWrapIds.
     * @return true if processed (decrypted, or definitively undecryptable data);
     *   false ONLY if the signer was unavailable for a silent decrypt (retryable).
     */
    internal suspend fun DMService.decryptGiftWrap(eventObj: JsonObject, eventId: String, generation: Int): Boolean {
        if (switchGeneration != generation) return true
        return withContext(Dispatchers.IO) {
            try {
                val giftWrapContent = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val giftWrapPubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypting (amber=${isAmberMode()})")

                val rumorJson = when (dmCryptoMode()) {
                    DMCrypto.AMBER ->
                        // Gift wrap → seal → rumor is TWO NIP-44 layers; Amber must
                        // decrypt both. silentOnly: a backlog drain must never fall back
                        // to an interactive Intent per message (floods the signer).
                        NIP17Service.unwrapGiftWrappedDMWithAmber(
                            giftWrapContent, giftWrapPubkey, amberSignerService, silentOnly = true,
                        ) ?: run {
                            if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} silent decrypt unavailable")
                            return@withContext false // signer can't silently decrypt → retryable
                        }
                    DMCrypto.BUNKER ->
                        // One bunker round trip at a time: a backlog of wraps must
                        // not open N concurrent RPCs to the same remote signer.
                        bunkerDecryptMutex.withLock {
                            unwrapGiftWrappedDMWithBunker(giftWrapContent, giftWrapPubkey)
                        } ?: run {
                            if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} bunker decrypt unavailable")
                            return@withContext false // signer unreachable → retryable
                        }
                    DMCrypto.LOCAL -> {
                        val recipientPrivkey = resolvePrivateKey()
                            ?: return@withContext false // key went away mid-flight → retryable
                        NIP17Service.unwrapGiftWrappedDM(giftWrapContent, giftWrapPubkey, recipientPrivkey)
                            ?: run { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypt returned NULL"); return@withContext true }
                    }
                    DMCrypto.NONE -> return@withContext false // no key here yet → retryable
                }

                // Parse the rumor JSON to extract sender, content, timestamp, tags
                val rumorObj = json.parseToJsonElement(rumorJson).jsonObject
                val senderPubkey = rumorObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val content = rumorObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext true
                val timestamp = rumorObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@withContext true
                val rumorTags = rumorObj["tags"]?.jsonArray?.map { t ->
                    t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                } ?: emptyList()
                val isFromMe = senderPubkey == nostrService.activeHexPubkey

                // Determine counterparty from rumor tags
                val counterparty = if (isFromMe) {
                    rumorTags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@withContext true
                } else {
                    senderPubkey
                }

                val message = DMMessage(
                    id = eventId,
                    content = content,
                    timestamp = timestamp,
                    senderPubkey = senderPubkey,
                    isFromMe = isFromMe,
                    isNIP04 = false,
                )

                recordOpened(counterparty, message)
                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(counterparty, message)
                }
                true
            } catch (e: Exception) {
                Log.w(TAG, "Gift wrap unwrap failed: ${e.message}")
                true // bad data — don't requeue
            }
        }
    }

    /**
     * Heuristic: does [content] look like a NIP-44 v2 payload rather than human
     * text? NIP-44 v2 = base64( 0x02 || nonce(32) || ciphertext || mac(32) ), so a
     * valid decode whose first byte is 0x02 and whose length is at least the
     * minimum (1+32+32+32 = 97 bytes) is almost certainly leftover ciphertext from
     * the old single-decrypt NIP-17 bug — not a real message. Used only to purge
     * corrupted cached entries on load.
     */
    internal fun DMService.looksLikeNip44Ciphertext(content: String): Boolean {
        if (content.length < 130 || content.any { it.isWhitespace() }) return false
        return try {
            val raw = android.util.Base64.decode(content, android.util.Base64.DEFAULT)
            raw.size >= 97 && raw[0].toInt() == 0x02
        } catch (_: Exception) {
            false
        }
    }
