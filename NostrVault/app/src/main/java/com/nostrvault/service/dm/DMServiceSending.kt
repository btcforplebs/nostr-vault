package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import com.nostrvault.service.DMService.Companion.MAX_SENT_SELF_WRAP_IDS
import com.nostrvault.service.DMService.Companion.TAG

    /**
     * @param file a locked photo ([DMFile]): sent as a kind 15 file message whose content is its
     *   link, and shown here as its link with what opens it. [content] is unused then.
     */
    internal suspend fun DMService.sendNIP17DM(content: String, recipientHexPubkey: String, file: DMFileSend? = null) {
        val generation = switchGeneration
        val cacheKey = loadedCacheKey
        val rumor = file?.let { DMRumor.file(it.message, it.notBefore) } ?: DMRumor()
        val shown = file?.message?.shown ?: content
        @Suppress("NAME_SHADOWING") val content = file?.message?.content ?: content

        // Optimistic UI update
        val optimisticId = UUID.randomUUID().toString()
        val optimisticMessage = DMMessage(
            id = optimisticId,
            content = shown,
            timestamp = maxOf(System.currentTimeMillis() / 1000, file?.notBefore ?: 0),
            senderPubkey = nostrService.activeHexPubkey,
            isFromMe = true,
            isNIP04 = false,
            sendState = DMSendState.SENDING,
            // A locked photo's link carries its key: never resent as words.
            resendText = if (file == null) content else null,
        )
        withContext(Dispatchers.Main.immediate) {
            addMessageToConversation(recipientHexPubkey, optimisticMessage)
        }

        // Create gift wraps in background
        withContext(Dispatchers.IO) {
            var publishing = false
            try {
                val ownHexPubkey = nostrService.activeHexPubkey

                val recipientEvent: String
                val selfEvent: String

                when (dmCryptoMode()) {
                    DMCrypto.AMBER -> {
                        // Amber mode: delegate NIP-44 encrypt + seal signing to Amber
                        recipientEvent = NIP17Service.createGiftWrappedDMWithAmber(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = recipientHexPubkey,
                            amberSignerService = amberSignerService,
                            rumor = rumor,
                        ) ?: throw Exception("Failed to create recipient wrap via Amber")
                        selfEvent = NIP17Service.createGiftWrappedDMWithAmber(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = recipientHexPubkey,
                            giftWrapRecipient = ownHexPubkey,
                            amberSignerService = amberSignerService,
                            rumor = rumor,
                        ) ?: throw Exception("Failed to create self wrap via Amber")
                    }
                    DMCrypto.BUNKER -> {
                        // One seal at a time: two concurrent sign requests to the
                        // same remote signer is how a bunker session gets wedged.
                        recipientEvent = createGiftWrappedDMWithBunker(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = recipientHexPubkey,
                            rumor = rumor,
                        ) ?: throw Exception("Your signer could not seal this message")
                        selfEvent = createGiftWrappedDMWithBunker(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = recipientHexPubkey,
                            giftWrapRecipient = ownHexPubkey,
                            rumor = rumor,
                        ) ?: throw Exception("Your signer could not seal your own copy")
                    }
                    DMCrypto.NONE -> throw Exception(
                        dmUnavailableReason() ?: "No key for this account on this device",
                    )
                    DMCrypto.LOCAL -> {
                        val privkey = resolvePrivateKey() ?: throw Exception("No private key")

                        // Create gift wraps concurrently
                        val recipientWrap = async {
                            NIP17Service.createGiftWrappedDM(
                                content = content,
                                senderSecretKey = privkey,
                                senderPubkey = ownHexPubkey,
                                recipientPubkey = recipientHexPubkey,
                                rumor = rumor,
                            )
                        }
                        val selfWrap = async {
                            NIP17Service.createGiftWrappedDM(
                                content = content,
                                senderSecretKey = privkey,
                                senderPubkey = ownHexPubkey,
                                recipientPubkey = recipientHexPubkey,
                                giftWrapRecipient = ownHexPubkey,
                                rumor = rumor,
                            )
                        }

                        recipientEvent = recipientWrap.await() ?: throw Exception("Failed to create recipient wrap")
                        selfEvent = selfWrap.await() ?: throw Exception("Failed to create self wrap")
                    }
                }

                if (switchGeneration != generation) throw DMAccountSwitchedException()

                // Find where the recipient reads before anything goes out (this
                // can wait seconds for their relay list): a message with nowhere
                // to go must not leave only your own copy behind, looking sent.
                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                if (recipientRelays.isEmpty()) throw Exception("Couldn't find a relay to reach them.")
                if (switchGeneration != generation) throw DMAccountSwitchedException()
                publishing = true

                // Pre-mark our own self-copy gift wrap as seen. It is addressed to
                // us (kind 1059, #p = self) so it echoes back through every DM
                // subscription; without this it would be decrypted again — a wasted
                // Amber round-trip per sent message for a message we already hold
                // optimistically. (Pattern borrowed from dark-wisp markGiftWrapSeen.)
                runCatching {
                    json.parseToJsonElement(selfEvent).jsonObject["id"]
                        ?.jsonPrimitive?.contentOrNull
                }.getOrNull()?.let {
                    seenGiftWrapIds.add(it)
                    // Its relay notification must not announce your own message.
                    if (sentSelfWrapIds.size > MAX_SENT_SELF_WRAP_IDS) sentSelfWrapIds.clear()
                    sentSelfWrapIds.add(it)
                }

                // Their relays first; your own copy (the vault, and your DM inbox
                // list, which every device reads from) only once one of theirs took
                // it. The bubble says "Sending…" meanwhile (dm/DMDelivery.kt).
                scope.launch {
                    deliverNIP17(cacheKey, recipientHexPubkey, optimisticId, recipientEvent, selfEvent, recipientRelays, ownHexPubkey)
                }
            } catch (e: CancellationException) {
                if (!publishing) takeBackOptimisticSend(cacheKey, recipientHexPubkey, optimisticId)
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "NIP-17 send failed: ${e.message}")
                if (!publishing) {
                    // Nothing went out: take back the optimistic bubble, from
                    // the old account's saved inbox if the account changed.
                    takeBackOptimisticSend(cacheKey, recipientHexPubkey, optimisticId)
                    throw e
                }
                setSendState(cacheKey, recipientHexPubkey, optimisticId, DMSendState.FAILED, e.message ?: "It didn't go out.")
            }
        }
    }

    internal suspend fun DMService.sendNIP04DM(content: String, recipientHexPubkey: String) {
        val generation = switchGeneration
        val cacheKey = loadedCacheKey

        withContext(Dispatchers.IO) {
            var publishing = false
            var publishedId: String? = null
            try {
                val encrypted = when (dmCryptoMode()) {
                    DMCrypto.AMBER -> amberSignerService.nip04Encrypt(content, recipientHexPubkey)
                        ?: throw Exception("Amber encryption failed")
                    DMCrypto.BUNKER -> {
                        if (!ensureDmBunkerConnected(nostrService.activeHexPubkey)) {
                            throw Exception("Your signer is not reachable")
                        }
                        NIP46Service.nip04Encrypt(recipientHexPubkey, content)
                            ?: throw Exception("Your signer could not encrypt this message")
                    }
                    DMCrypto.NONE -> throw Exception(
                        dmUnavailableReason() ?: "No key for this account on this device",
                    )
                    DMCrypto.LOCAL -> {
                        val privkey = resolvePrivateKey() ?: throw Exception("No private key")
                        NIP04Service.encrypt(content, recipientHexPubkey, privkey)
                            ?: throw Exception("Encryption failed")
                    }
                }

                val tags = listOf(listOf("p", recipientHexPubkey))
                // Use the async, signing-mode-aware path so NIP-04 sends work under
                // Amber / NIP-46 (the sync signEvent only handles a local key).
                val event = nostrService.signEventAsync(kind = 4, content = encrypted, tags = tags)
                    ?: throw Exception("Signing failed")

                if (switchGeneration != generation) throw DMAccountSwitchedException()
                publishing = true
                publishedId = event.id

                // Optimistic UI
                val message = DMMessage(
                    id = event.id,
                    content = content,
                    timestamp = event.createdAt,
                    senderPubkey = event.pubkey,
                    isFromMe = true,
                    isNIP04 = true,
                    sendState = DMSendState.SENDING,
                    resendText = content,
                )
                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(recipientHexPubkey, message)
                }

                // Their relays first; the vault and your own relays (a kind 4 has
                // no self-copy, so your other devices read it there) once one of
                // theirs took it (dm/DMDelivery.kt).
                val eventJson = serializeEvent(event)
                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                val ownRelays = fetchRecipientDMRelays(nostrService.activeHexPubkey)
                scope.launch {
                    deliverNIP04(cacheKey, recipientHexPubkey, event.id, eventJson, recipientRelays, ownRelays)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "NIP-04 send failed: ${e.message}")
                if (!publishing) throw e
                setSendState(cacheKey, recipientHexPubkey, publishedId ?: return@withContext, DMSendState.FAILED, e.message ?: "It didn't go out.")
            }
        }
    }
