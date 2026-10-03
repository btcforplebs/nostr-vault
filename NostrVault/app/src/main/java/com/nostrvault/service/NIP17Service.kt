package com.nostrvault.service

import android.util.Log

/**
 * Port of NIP17Service.swift -- gift-wrap encryption chain for private DMs.
 *
 * NIP-17 encryption chain: rumor -> seal -> gift wrap
 *   1. Create unsigned "rumor" event (kind 14 DM content)
 *   2. Seal the rumor with NIP-44 encryption to the recipient
 *   3. Gift-wrap the sealed event with a random ephemeral key
 *
 * All crypto operations delegate to HavenBridge (Go FFI) for NIP-44
 * encryption and event signing.
 */
object NIP17Service {

    private const val TAG = "NIP17Service"

    /**
     * Create a NIP-17 gift-wrapped DM.
     *
     * @param content The plaintext DM content
     * @param senderSecretKey Sender's secret key hex
     * @param senderPubkey Sender's public key hex
     * @param recipientPubkey Recipient's public key hex
     * @return Gift-wrapped event JSON string ready to publish, or null on failure
     */
    fun createGiftWrappedDM(
        content: String,
        senderSecretKey: String,
        senderPubkey: String,
        recipientPubkey: String,
    ): String? {
        try {
            // Step 1: Build the rumor (unsigned kind 14)
            val rumorJson = EventPublisher.buildUnsignedEvent(
                pubkey = senderPubkey,
                kind = 14,
                content = content,
                tags = listOf(listOf("p", recipientPubkey)),
            )

            // Step 2: Seal with NIP-44 (encrypt rumor for recipient)
            val sealedContent = NIP44Service.encrypt(rumorJson, recipientPubkey, senderSecretKey)
                ?: run {
                    Log.e(TAG, "Failed to NIP-44 encrypt rumor")
                    return null
                }

            val sealEventJson = EventPublisher.buildUnsignedEvent(
                pubkey = senderPubkey,
                kind = 13,
                content = sealedContent,
                tags = emptyList(),
            )

            val signedSeal = EventPublisher.signWithGoBackend(sealEventJson, senderSecretKey)
                ?: run {
                    Log.e(TAG, "Failed to sign seal event")
                    return null
                }

            // Step 3: Gift-wrap with ephemeral key
            val ephemeralKeyPair = com.nostrvault.relay.HavenBridge.generateKeyPair()
                ?: run {
                    Log.e(TAG, "Failed to generate ephemeral keypair")
                    return null
                }

            val parts = ephemeralKeyPair.split(":")
            if (parts.size != 2) {
                Log.e(TAG, "Invalid keypair format")
                return null
            }
            val ephemeralSk = parts[0]
            val ephemeralPk = parts[1]

            // Encrypt the signed seal for the recipient
            val wrappedContent = NIP44Service.encrypt(signedSeal, recipientPubkey, ephemeralSk)
                ?: run {
                    Log.e(TAG, "Failed to NIP-44 encrypt seal for gift wrap")
                    return null
                }

            val giftWrapJson = EventPublisher.buildUnsignedEvent(
                pubkey = ephemeralPk,
                kind = 1059,
                content = wrappedContent,
                tags = listOf(listOf("p", recipientPubkey)),
            )

            return EventPublisher.signWithGoBackend(giftWrapJson, ephemeralSk)
        } catch (e: Exception) {
            Log.e(TAG, "Gift wrap creation failed: ${e.message}")
            return null
        }
    }

    /**
     * Create a NIP-17 gift-wrapped DM using Amber for crypto operations.
     * The user's private key never leaves Amber -- NIP-44 encryption and
     * event signing are delegated to the external signer.
     *
     * Encryption chain:
     *   1. Build unsigned rumor (kind 14)
     *   2. NIP-44 encrypt rumor → sealed content (via Amber)
     *   3. Build + sign seal event (kind 13) (via Amber)
     *   4. NIP-44 encrypt seal with ephemeral key (Go backend -- no user key needed)
     *   5. Build + sign gift wrap (kind 1059) with ephemeral key (Go backend)
     */
    suspend fun createGiftWrappedDMWithAmber(
        content: String,
        senderPubkey: String,
        recipientPubkey: String,
        amberSignerService: AmberSignerService,
    ): String? {
        try {
            // Step 1: Build the rumor (unsigned kind 14)
            val rumorJson = EventPublisher.buildUnsignedEvent(
                pubkey = senderPubkey,
                kind = 14,
                content = content,
                tags = listOf(listOf("p", recipientPubkey)),
            )

            // Step 2: Amber NIP-44 encrypts the rumor for the recipient
            val sealedContent = amberSignerService.nip44Encrypt(rumorJson, recipientPubkey)
                ?: run {
                    Log.e(TAG, "Amber NIP-44 encrypt failed for seal")
                    return null
                }

            // Step 3: Build seal event and sign with Amber
            val sealEventJson = EventPublisher.buildUnsignedEvent(
                pubkey = senderPubkey,
                kind = 13,
                content = sealedContent,
                tags = emptyList(),
            )

            val signedSeal = amberSignerService.signEvent(sealEventJson)
                ?: run {
                    Log.e(TAG, "Amber failed to sign seal event")
                    return null
                }

            // Step 4: Gift-wrap with ephemeral key (no user key needed)
            val ephemeralKeyPair = com.nostrvault.relay.HavenBridge.generateKeyPair()
                ?: run {
                    Log.e(TAG, "Failed to generate ephemeral keypair")
                    return null
                }

            val parts = ephemeralKeyPair.split(":")
            if (parts.size != 2) {
                Log.e(TAG, "Invalid keypair format")
                return null
            }
            val ephemeralSk = parts[0]
            val ephemeralPk = parts[1]

            // Encrypt the signed seal for the recipient (ephemeral key -- no Amber needed)
            val wrappedContent = NIP44Service.encrypt(signedSeal, recipientPubkey, ephemeralSk)
                ?: run {
                    Log.e(TAG, "Failed to NIP-44 encrypt seal for gift wrap")
                    return null
                }

            val giftWrapJson = EventPublisher.buildUnsignedEvent(
                pubkey = ephemeralPk,
                kind = 1059,
                content = wrappedContent,
                tags = listOf(listOf("p", recipientPubkey)),
            )

            return EventPublisher.signWithGoBackend(giftWrapJson, ephemeralSk)
        } catch (e: Exception) {
            Log.e(TAG, "Amber gift wrap creation failed: ${e.message}")
            return null
        }
    }

    /**
     * Unwrap a received NIP-17 gift-wrapped DM using Amber for decryption.
     *
     * The gift-wrap chain is TWO encrypted layers and therefore needs TWO
     * NIP-44 decrypts (this was the Android Amber bug: only one was performed,
     * so the still-encrypted seal was parsed as the rumor → garbled DMs).
     * Mirrors iOS NIP17Service.unwrapGiftWrapAsync (NIP-46 branch):
     *   1. decrypt gift wrap (ephemeral pubkey) → seal event (kind 13)
     *   2. decrypt seal content (sealer pubkey)  → rumor JSON (kind 14)
     *
     * @param giftWrapContent The encrypted content of the gift wrap event
     * @param giftWrapPubkey The ephemeral pubkey of the gift wrap
     * @param amberSignerService Signer used for both NIP-44 decrypts
     * @return The decrypted rumor JSON, or null on failure
     */
    suspend fun unwrapGiftWrappedDMWithAmber(
        giftWrapContent: String,
        giftWrapPubkey: String,
        amberSignerService: AmberSignerService,
        silentOnly: Boolean = false,
    ): String? {
        try {
            // Step 1: Amber decrypts the gift wrap → seal (kind 13) JSON.
            val sealJson = amberSignerService.nip44Decrypt(giftWrapContent, giftWrapPubkey, silentOnly)
                ?: run {
                    Log.e(TAG, "Amber failed to decrypt gift wrap")
                    return null
                }

            val sealObj = try {
                kotlinx.serialization.json.Json.parseToJsonElement(sealJson).jsonObject
            } catch (_: Exception) {
                Log.e(TAG, "Failed to parse seal JSON")
                return null
            }

            val sealerPubkey = sealObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null
            val sealContent = sealObj["content"]?.jsonPrimitive?.contentOrNull ?: return null

            // Step 2: Amber decrypts the seal content → rumor (kind 14) JSON.
            val rumorJson = amberSignerService.nip44Decrypt(sealContent, sealerPubkey, silentOnly)
                ?: run {
                    Log.e(TAG, "Amber failed to decrypt seal")
                    return null
                }

            return rumorJson.takeIf { isAuthoredBySealer(sealObj, it) }
        } catch (e: Exception) {
            Log.e(TAG, "Amber gift wrap unwrap failed: ${e.message}")
            return null
        }
    }

    /**
     * Unwrap a received NIP-17 gift-wrapped DM.
     *
     * @param giftWrapContent The encrypted content of the gift wrap event
     * @param giftWrapPubkey The ephemeral pubkey of the gift wrap
     * @param recipientSecretKey The recipient's secret key hex
     * @return The decrypted rumor JSON, or null on failure
     */
    fun unwrapGiftWrappedDM(
        giftWrapContent: String,
        giftWrapPubkey: String,
        recipientSecretKey: String,
    ): String? {
        try {
            // Decrypt the gift wrap to get the sealed event
            val sealJson = NIP44Service.decrypt(giftWrapContent, giftWrapPubkey, recipientSecretKey)
                ?: run {
                    Log.e(TAG, "Failed to decrypt gift wrap")
                    return null
                }

            // Parse the seal to get sender pubkey and encrypted content
            val sealObj = try {
                kotlinx.serialization.json.Json.parseToJsonElement(sealJson).jsonObject
            } catch (_: Exception) {
                Log.e(TAG, "Failed to parse seal JSON")
                return null
            }

            val sealerPubkey = sealObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null
            val sealContent = sealObj["content"]?.jsonPrimitive?.contentOrNull ?: return null

            // Decrypt the seal to get the rumor
            val rumorJson = NIP44Service.decrypt(sealContent, sealerPubkey, recipientSecretKey)
                ?: return null
            return rumorJson.takeIf { isAuthoredBySealer(sealObj, it) }
        } catch (e: Exception) {
            Log.e(TAG, "Gift wrap unwrap failed: ${e.message}")
            return null
        }
    }

    /**
     * Impersonation guard (parity with iOS NIP17Service). The seal decrypts only
     * under its sealer's key, so the sealer is the one authenticated sender; the
     * rumor's pubkey is just a claim inside it. Anyone can seal with their own key
     * and claim another author — or claim to be the recipient themselves.
     */
    internal fun isAuthoredBySealer(sealObj: kotlinx.serialization.json.JsonObject, rumorJson: String): Boolean {
        val rumorObj = try {
            kotlinx.serialization.json.Json.parseToJsonElement(rumorJson).jsonObject
        } catch (_: Exception) {
            Log.e(TAG, "Failed to parse rumor JSON")
            return false
        }
        val sealKind = (sealObj["kind"] as? kotlinx.serialization.json.JsonPrimitive)?.content
        val rumorKind = (rumorObj["kind"] as? kotlinx.serialization.json.JsonPrimitive)?.content
        if (sealKind != "13" || rumorKind != "14") {
            Log.w(TAG, "Unexpected seal/rumor kind ($sealKind/$rumorKind), dropping")
            return false
        }
        val sealerPubkey = sealObj["pubkey"]?.jsonPrimitive?.contentOrNull
        val rumorPubkey = rumorObj["pubkey"]?.jsonPrimitive?.contentOrNull
        if (sealerPubkey == null || rumorPubkey != sealerPubkey) {
            Log.w(TAG, "Seal pubkey != rumor pubkey — possible impersonation, dropping")
            return false
        }
        return true
    }
}

// Extension imports for JSON parsing
private val kotlinx.serialization.json.JsonElement.jsonObject
    get() = this as kotlinx.serialization.json.JsonObject
private val kotlinx.serialization.json.JsonElement.jsonPrimitive
    get() = (this as kotlinx.serialization.json.JsonPrimitive)
private val kotlinx.serialization.json.JsonPrimitive.contentOrNull: String?
    get() = if (isString) content else null
