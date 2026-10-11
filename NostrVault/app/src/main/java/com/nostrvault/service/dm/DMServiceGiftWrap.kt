package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.TAG

    internal suspend fun DMService.handleIncomingGiftWrap(eventObj: JsonObject, generation: Int) {
        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        if (switchGeneration != generation) return
        if (seenGiftWrapIds.contains(eventId)) { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} skipped (already seen)"); return }
        // Before any seen/queued claim, so a forged copy carrying a real event's
        // id cannot shadow the real one. A relay can serve any event under any
        // author; NIP-04 has no MAC, so a re-IV'd copy of a real DM decrypts to
        // altered text. Only the signature ties it to its author.
        if (!HavenBridge.verifyEvent(eventObj.toString())) return

        // Amber mode: queue instead of decrypting now (see pendingDecryptQueue).
        if (isAmberMode()) { enqueuePendingDecrypt(eventObj, eventId); return }

        // Local key: decrypt eagerly — cheap, no signer IPC or prompts.
        if (!seenGiftWrapIds.add(eventId)) return
        decryptGiftWrap(eventObj, eventId, generation)
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

                val rumorJson = if (isAmberMode()) {
                    // Gift wrap → seal → rumor is TWO NIP-44 layers; Amber must
                    // decrypt both. silentOnly: a backlog drain must never fall back
                    // to an interactive Intent per message (floods the signer).
                    NIP17Service.unwrapGiftWrappedDMWithAmber(
                        giftWrapContent, giftWrapPubkey, amberSignerService, silentOnly = true,
                    ) ?: run {
                        if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} silent decrypt unavailable")
                        return@withContext false // signer can't silently decrypt → retryable
                    }
                } else {
                    val recipientPrivkey = resolvePrivateKey() ?: return@withContext true
                    NIP17Service.unwrapGiftWrappedDM(giftWrapContent, giftWrapPubkey, recipientPrivkey)
                        ?: run { if (BuildConfig.DEBUG) Log.w(TAG, "DBG: giftwrap ${eventId.take(8)} decrypt returned NULL"); return@withContext true }
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
