package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.TAG

/**
 * How the ACTIVE account can do DM crypto. Android used to ask only whether the
 * owner's global signing mode was "amber" and otherwise reach for a local key,
 * so a bunker (NIP-46) or watch-only account silently dropped every inbound DM
 * and threw on every send, and a second account's DMs were sealed with the
 * OWNER's key — never delivered, and linking the two accounts.
 */
internal enum class DMCrypto {
    /** A secret key for the active account is on this device. */
    LOCAL,

    /** Amber (external signer app) holds the key. */
    AMBER,

    /** A NIP-46 bunker holds the key. */
    BUNKER,

    /** Watch-only: no key anywhere, so DMs can be neither read nor sent. */
    NONE,
}

/**
 * The DM crypto available to the account that is active right now. Resolved per
 * account from [com.nostrvault.relay.HavenConfig.activeSigningMode], never from
 * the owner's global mode.
 */
internal fun DMService.dmCryptoMode(): DMCrypto =
    when (configStore.config.value.activeSigningMode()) {
        "amber" -> DMCrypto.AMBER
        "nip46" -> DMCrypto.BUNKER
        else -> if (hasLocalDmKey()) DMCrypto.LOCAL else DMCrypto.NONE
    }

/**
 * Whether key material for the active account is PRESENT on this device.
 * Checks the same sources [resolvePrivateKey] would use but never decrypts, so
 * it is cheap enough to ask per inbound DM — a NIP-49 scrypt per event is not.
 * Mirrors iOS DMService.canDecryptNIP04's presence-only branching.
 */
internal fun DMService.hasLocalDmKey(): Boolean {
    val config = configStore.config.value
    val activeNpub = config.activeAccountNpub?.trim().orEmpty()
    val asOwner = activeNpub.isEmpty() || activeNpub == config.ownerNpub
    return if (asOwner) {
        if (!config.ownerHexKey.isNullOrEmpty()) return true
        val npub = config.ownerNpub
        if (config.ownerNcryptsec != null && npub.isNotEmpty() &&
            credentialStore.getKeychainPassword(npub) != null
        ) {
            return true
        }
        nostrService.ownerHexPubkey.isNotEmpty() &&
            credentialStore.getNsec(nostrService.ownerHexPubkey) != null
    } else {
        if (credentialStore.getCredentialHexKey(activeNpub) != null) return true
        val hex = com.nostrvault.relay.HavenBridge.decodeNpub(activeNpub) ?: return false
        credentialStore.getNsec(hex) != null
    }
}

/**
 * Logs the watch-only case once per account instead of once per dropped DM.
 * Reset on an account switch (see switchAccount).
 */
internal fun DMService.warnNoDmKeyOnce() {
    if (warnedNoDmKey.compareAndSet(false, true)) {
        Log.w(TAG, "No DM key for the active account — inbound private messages cannot be opened here")
    }
}

/** Why this account can't use DMs, or null when it can. */
internal fun DMService.dmUnavailableReason(): String? =
    if (dmCryptoMode() == DMCrypto.NONE) {
        "This account is watch-only on this device: there is no key here to read or send private messages."
    } else {
        null
    }

// ══════════════════════════════════════════════════════════════════
// NIP-17 gift wrap via a NIP-46 bunker
// ══════════════════════════════════════════════════════════════════

/**
 * Builds a NIP-17 gift wrap with the active account's bunker: the seal's
 * NIP-44 encrypt and signature are the signer's, the outer wrap stays local
 * (ephemeral key). Same chain as iOS NIP17Service.createGiftWrapAsync's
 * NIP-46 branch and as [NIP17Service.createGiftWrappedDMWithAmber].
 */
internal suspend fun DMService.createGiftWrappedDMWithBunker(
    content: String,
    senderPubkey: String,
    recipientPubkey: String,
): String? = withContext(Dispatchers.IO) {
    try {
        if (!ensureDmBunkerConnected(senderPubkey)) return@withContext null

        val rumorJson = EventPublisher.buildUnsignedEvent(
            pubkey = senderPubkey,
            kind = 14,
            content = content,
            tags = listOf(listOf("p", recipientPubkey)),
        )

        val sealedContent = NIP46Service.nip44Encrypt(recipientPubkey, rumorJson)
            ?: run { Log.e(TAG, "Bunker NIP-44 encrypt failed for seal"); return@withContext null }

        val sealEventJson = EventPublisher.buildUnsignedEvent(
            pubkey = senderPubkey,
            kind = 13,
            content = sealedContent,
            tags = emptyList(),
        )
        val signedSeal = NIP46Service.signEvent(sealEventJson, userInitiated = true)
            ?: run { Log.e(TAG, "Bunker failed to sign seal event"); return@withContext null }

        // A valid signature proves nothing about identity: a signer paired to
        // another account signs happily as that account, and the recipient's
        // own impersonation guard would then drop the message. Refuse here.
        if (!sealSignedAsRequested(sealEventJson, signedSeal)) return@withContext null

        wrapSealWithEphemeralKey(signedSeal, recipientPubkey)
    } catch (e: Exception) {
        Log.e(TAG, "Bunker gift wrap creation failed: ${e.message}")
        null
    }
}

/**
 * Unwraps an inbound gift wrap through the bunker. Two NIP-44 layers (wrap →
 * seal → rumor), and the rumor is kept only if its author is the seal's signer
 * ([NIP17Service.isAuthoredBySealer]).
 */
internal suspend fun DMService.unwrapGiftWrappedDMWithBunker(
    giftWrapContent: String,
    giftWrapPubkey: String,
): String? = withContext(Dispatchers.IO) {
    try {
        if (!ensureDmBunkerConnected(nostrService.activeHexPubkey)) return@withContext null

        val sealJson = NIP46Service.nip44Decrypt(giftWrapPubkey, giftWrapContent)
            ?: run { Log.e(TAG, "Bunker failed to decrypt gift wrap"); return@withContext null }

        val sealObj = runCatching { Json.parseToJsonElement(sealJson).jsonObject }.getOrNull()
            ?: run { Log.e(TAG, "Failed to parse seal JSON"); return@withContext null }

        val sealerPubkey = sealObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@withContext null
        val sealContent = sealObj["content"]?.jsonPrimitive?.contentOrNull ?: return@withContext null

        val rumorJson = NIP46Service.nip44Decrypt(sealerPubkey, sealContent)
            ?: run { Log.e(TAG, "Bunker failed to decrypt seal"); return@withContext null }

        rumorJson.takeIf { NIP17Service.isAuthoredBySealer(sealObj, it) }
    } catch (e: Exception) {
        Log.e(TAG, "Bunker gift wrap unwrap failed: ${e.message}")
        null
    }
}

/**
 * NIP-44 encrypts [signedSeal] for [recipientPubkey] under a throwaway key and
 * signs the kind-1059 wrap with it. Never touches the user's key, so it is the
 * same for every signing mode.
 */
private fun DMService.wrapSealWithEphemeralKey(signedSeal: String, recipientPubkey: String): String? {
    val parts = com.nostrvault.relay.HavenBridge.generateKeyPair()?.split(":")
    if (parts == null || parts.size != 2) {
        Log.e(TAG, "Failed to generate ephemeral keypair")
        return null
    }
    val (ephemeralSk, ephemeralPk) = parts

    val wrappedContent = NIP44Service.encrypt(signedSeal, recipientPubkey, ephemeralSk)
        ?: run { Log.e(TAG, "Failed to NIP-44 encrypt seal for gift wrap"); return null }

    val giftWrapJson = EventPublisher.buildUnsignedEvent(
        pubkey = ephemeralPk,
        kind = 1059,
        content = wrappedContent,
        tags = listOf(listOf("p", recipientPubkey)),
    )
    return EventPublisher.signWithGoBackend(giftWrapJson, ephemeralSk)
}

/**
 * The Go bunker session only lives in this process: after a restart nothing
 * reconnects it until an account switch, so every DM sign and decrypt failed.
 * Reconnects the active account's stored bunker, refusing a signer that answers
 * for another key (handled inside [NIP46Service.connectForAccount]).
 */
internal suspend fun DMService.ensureDmBunkerConnected(expectedPubkey: String): Boolean {
    if (NIP46Service.isConnected.value && NIP46Service.connectedPubkey == expectedPubkey) return true
    val config = configStore.config.value
    val bunker = config.bunkerConfig(config.activeOrOwnerNpub()) ?: run {
        Log.w(TAG, "No bunker configured for the active account")
        return false
    }
    val connected = NIP46Service.connectForAccount(bunker, expectedPubkey)
    if (connected == null) {
        Log.w(TAG, "Bunker not reachable: ${NIP46Service.lastError.value ?: "unknown"}")
        return false
    }
    return true
}

/**
 * True when the signer returned the seal we asked it to sign, as the account we
 * asked for. Mirrors NostrService.requireSignedAsRequested; a signer that
 * changed the content or signed as someone else must not be published.
 */
private fun DMService.sealSignedAsRequested(requestJson: String, signedJson: String): Boolean {
    val want = runCatching { json.parseToJsonElement(requestJson).jsonObject }.getOrNull() ?: return false
    val got = runCatching { json.parseToJsonElement(signedJson).jsonObject }.getOrNull() ?: return false
    fun field(obj: JsonObject, key: String) = obj[key]?.jsonPrimitive?.contentOrNull
    if (field(got, "pubkey") != field(want, "pubkey")) {
        Log.w(TAG, "Bunker signed the seal as another account — dropping")
        return false
    }
    if (field(got, "content") != field(want, "content") ||
        got["kind"]?.jsonPrimitive?.intOrNull != want["kind"]?.jsonPrimitive?.intOrNull
    ) {
        Log.w(TAG, "Bunker changed the seal it was asked to sign — dropping")
        return false
    }
    return true
}
