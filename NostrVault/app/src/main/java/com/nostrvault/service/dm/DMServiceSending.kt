package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import com.nostrvault.service.DMService.Companion.MAX_SENT_SELF_WRAP_IDS
import com.nostrvault.service.DMService.Companion.TAG

    internal suspend fun DMService.sendNIP17DM(content: String, recipientHexPubkey: String) {
        val generation = switchGeneration

        // Optimistic UI update
        val optimisticId = UUID.randomUUID().toString()
        val optimisticMessage = DMMessage(
            id = optimisticId,
            content = content,
            timestamp = System.currentTimeMillis() / 1000,
            senderPubkey = nostrService.activeHexPubkey,
            isFromMe = true,
            isNIP04 = false,
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
                        ) ?: throw Exception("Failed to create recipient wrap via Amber")
                        selfEvent = NIP17Service.createGiftWrappedDMWithAmber(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = ownHexPubkey,
                            amberSignerService = amberSignerService,
                        ) ?: throw Exception("Failed to create self wrap via Amber")
                    }
                    DMCrypto.BUNKER -> {
                        // One seal at a time: two concurrent sign requests to the
                        // same remote signer is how a bunker session gets wedged.
                        recipientEvent = createGiftWrappedDMWithBunker(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = recipientHexPubkey,
                        ) ?: throw Exception("Your signer could not seal this message")
                        selfEvent = createGiftWrappedDMWithBunker(
                            content = content,
                            senderPubkey = ownHexPubkey,
                            recipientPubkey = ownHexPubkey,
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
                            )
                        }
                        val selfWrap = async {
                            NIP17Service.createGiftWrappedDM(
                                content = content,
                                senderSecretKey = privkey,
                                senderPubkey = ownHexPubkey,
                                recipientPubkey = ownHexPubkey,
                            )
                        }

                        recipientEvent = recipientWrap.await() ?: throw Exception("Failed to create recipient wrap")
                        selfEvent = selfWrap.await() ?: throw Exception("Failed to create self wrap")
                    }
                }

                if (switchGeneration != generation) return@withContext
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

                // Publish to local /chat relay
                val config = configStore.config.value
                val chatUrl = config.localRelayURL("chat")
                chatUrl?.let {
                    inboxClient?.send("[\"EVENT\",$recipientEvent]")
                    inboxClient?.send("[\"EVENT\",$selfEvent]")
                }

                // Your own copy goes to your DM inbox list — the list every
                // device reads from, Mac relay first — never to whichever of
                // your relay lists a lookup finds first. Resolving it like a
                // recipient's could land on your general (kind 10002) relays,
                // which no device reads DMs from, so the message never showed
                // on your other devices.
                for (relayUrl in ownDMInboxRelays(ownHexPubkey)) {
                    publishAuthenticated(selfEvent, relayUrl, ownHexPubkey)
                }

                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                for (relayUrl in recipientRelays) {
                    publishAuthenticated(recipientEvent, relayUrl, ownHexPubkey)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "NIP-17 send failed: ${e.message}")
                if (!publishing) {
                    // Nothing went out: take back the optimistic bubble.
                    withContext(Dispatchers.Main.immediate) {
                        removeMessageFromConversation(recipientHexPubkey, optimisticId)
                    }
                    throw e
                }
            }
        }
    }

    internal suspend fun DMService.sendNIP04DM(content: String, recipientHexPubkey: String) {
        val generation = switchGeneration

        withContext(Dispatchers.IO) {
            var publishing = false
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

                if (switchGeneration != generation) return@withContext
                publishing = true

                // Optimistic UI
                val message = DMMessage(
                    id = event.id,
                    content = content,
                    timestamp = event.createdAt,
                    senderPubkey = event.pubkey,
                    isFromMe = true,
                    isNIP04 = true,
                )
                withContext(Dispatchers.Main.immediate) {
                    addMessageToConversation(recipientHexPubkey, message)
                }

                // Publish to local relay
                val eventJson = serializeEvent(event)
                val config = configStore.config.value
                config.localInboxURL?.let {
                    nip04Client?.send("[\"EVENT\",$eventJson]")
                }

                // Fire-and-forget to recipient's relays
                val recipientRelays = fetchRecipientDMRelays(recipientHexPubkey)
                for (relayUrl in recipientRelays) {
                    fireAndForgetPublish(eventJson, relayUrl)
                }

                // Also publish to our OWN relays so other devices on this account can
                // fetch the message we just sent. A kind-4 event carries no self-copy,
                // so without this the sent message is stranded on the local relay.
                val ownHexPubkey = nostrService.activeHexPubkey
                val ownRelays = fetchRecipientDMRelays(ownHexPubkey)
                for (relayUrl in ownRelays) {
                    if (relayUrl in recipientRelays) continue
                    fireAndForgetPublish(eventJson, relayUrl)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "NIP-04 send failed: ${e.message}")
                if (!publishing) throw e
            }
        }
    }
