package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.NIP46Service
import com.nostrvault.service.NIP49Service
import com.nostrvault.setup.IdentityInput
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import javax.inject.Inject

@HiltViewModel
class AccountSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val nostrService: NostrService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val nip46Connected: StateFlow<Boolean> = NIP46Service.isConnected

    fun hexFor(npub: String): String = HavenBridge.decodeNpub(npub) ?: ""
    fun profileFor(npub: String): FeedProfile? = profiles.value[hexFor(npub)]

    fun ensureProfiles(npubs: List<String>) {
        val hexes = npubs.mapNotNull { HavenBridge.decodeNpub(it) }
        if (hexes.isNotEmpty()) nostrService.fetchMissingProfiles(hexes)
    }

    fun hasLocalKey(npub: String, cfg: HavenConfig): Boolean {
        if (npub == cfg.ownerNpub) {
            return cfg.ownerHexKey != null || cfg.ownerNcryptsec != null ||
                (hexFor(npub).isNotEmpty() && credentialStore.getNsec(hexFor(npub)) != null)
        }
        return credentialStore.getCredentialHexKey(npub) != null ||
            (hexFor(npub).isNotEmpty() && credentialStore.getNsec(hexFor(npub)) != null)
    }

    fun switchTo(npub: String) = viewModelScope.launch { configStore.switchActiveAccount(npub) }

    /** Add a view-only account from an npub (no signing key). */
    fun addViewOnly(npub: String) {
        val clean = npub.trim()
        if (!clean.startsWith("npub1")) return
        configStore.addAccount(clean)
        configStore.setSigningMode(clean, "local")
        ensureProfiles(listOf(clean))
    }

    /** Import a signing account from an nsec. Returns the resulting npub or null. */
    fun importKey(nsec: String): String? {
        val hex = HavenBridge.decodeNsec(nsec.trim()) ?: return null
        return importKeyHex(hex)
    }

    /**
     * Import a signing account from a NIP-49 ncryptsec and the password it was
     * made with. Returns the resulting npub, or null when the password doesn't
     * unlock it.
     */
    suspend fun importEncryptedKey(ncryptsec: String, password: String): String? {
        val hex = withContext(Dispatchers.IO) {
            runCatching { NIP49Service.decrypt(ncryptsec.trim(), password) }.getOrNull()
        } ?: return null
        return importKeyHex(hex)
    }

    private fun importKeyHex(hex: String): String? {
        val pub = HavenBridge.getPublicKey(hex) ?: return null
        val npub = HavenBridge.encodeNpub(pub) ?: return null
        credentialStore.storeCredentialHexKey(hex, npub)
        credentialStore.saveNsec(hex, pub)
        configStore.addAccount(npub)
        configStore.setSigningMode(npub, "local")
        ensureProfiles(listOf(npub))
        return npub
    }

    /**
     * Gives an account that has no key on this device its private key, as
     * iOS "Import Private Key" does. [key] is an nsec (locked with a new
     * [password], typed twice) or an ncryptsec ([password] unlocks it). The
     * Vault's own account keeps it NIP-49 encrypted with the password in the
     * keystore, the way setup stores it; other accounts go into the keystore
     * the way Add Account stores them. Returns an error message, or null.
     */
    suspend fun importKeyFor(npub: String, key: String, password: String, confirm: String): String? {
        val input = IdentityInput.parse(key)
        val isOwner = npub == config.value.ownerNpub
        importKeyProblem(input, password, confirm, newPassword = isOwner)?.let { return it }
        val skHex = when (input) {
            is IdentityInput.SecretKey -> HavenBridge.decodeNsec(input.key)
                ?: return "That key doesn't look complete."
            is IdentityInput.EncryptedSecretKey -> withContext(Dispatchers.IO) {
                runCatching { NIP49Service.decrypt(input.key, password) }.getOrNull()
            } ?: return "That password didn't unlock the key."
            else -> return "Paste an nsec1… or ncryptsec1… key."
        }
        val pkHex = HavenBridge.getPublicKey(skHex) ?: return "Failed to derive public key"
        if (pkHex != hexFor(npub)) return "That key belongs to a different account."
        if (isOwner) {
            val encrypted = (input as? IdentityInput.EncryptedSecretKey)?.key
                ?: withContext(Dispatchers.IO) { runCatching { NIP49Service.encrypt(skHex, password) }.getOrNull() }
                ?: return "Failed to import and encrypt key"
            configStore.update { it.copy(ownerHexKey = skHex, ownerNcryptsec = encrypted) }
            credentialStore.storeKeychainPassword(password = password, npub = npub)
        } else {
            credentialStore.storeCredentialHexKey(skHex, npub)
        }
        credentialStore.saveNsec(skHex, pkHex)
        // A browse-only Vault (setup given just an npub) can post from now on.
        if (config.value.signingMode(npub) == "browse") {
            configStore.update { if (isOwner) it.copy(signingMode = "local", setupMode = "full") else it }
            configStore.setSigningMode(npub, "local")
        }
        _keysChanged.value++
        return null
    }

    /** Connect a NIP-46 remote signer. Returns the account npub or null. */
    fun connectSigner(bunkerUri: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            val keypair = HavenBridge.generateKeyPair()
            val parts = keypair?.split(":")
            if (parts == null || parts.size != 2) { onResult(null); return@launch }
            onResult(addSignerAccount(bunkerUri.trim(), parts[0], parts[1]))
        }
    }

    /**
     * Finishes a nostrconnect:// pairing: stored like a pasted bunker link
     * (secret-less, with the pairing's own client key), then connected.
     * Returns the account npub or null. Runs in the view model's scope so
     * leaving the screen mid-connect doesn't cut the save in half.
     */
    suspend fun pairNostrConnect(request: NIP46Service.NostrConnectRequest, signerPubkey: String): String? =
        viewModelScope.async {
            addSignerAccount(
                NIP46Service.bunkerUri(signerPubkey, request.relays),
                request.clientSecretKey,
                request.clientPubkey,
            )
        }.await()

    private suspend fun addSignerAccount(uri: String, clientSec: String, clientPub: String): String? {
        val signerPubkey = NIP46Service.connect(clientSec, uri) ?: return null
        val npub = HavenBridge.encodeNpub(signerPubkey) ?: return null
        configStore.setBunkerConfig(
            npub,
            AccountBunkerConfig(
                bunkerURI = uri,
                signerPubkey = signerPubkey,
                clientSecretKey = clientSec,
                clientPubkey = clientPub,
            ),
        )
        configStore.addAccount(npub)
        configStore.setSigningMode(npub, "nip46")
        ensureProfiles(listOf(npub))
        return npub
    }

    /**
     * Connects a pasted bunker link to [npub], an account already here (iOS
     * ConnectSignerSheetView.connectBunker). The signer must answer as this
     * account's key. Returns the message to show, or null once stored. Runs
     * in the view model's scope so closing the sheet mid-connect doesn't cut
     * the save in half.
     */
    suspend fun connectSignerFor(npub: String, bunkerUri: String): String? =
        viewModelScope.async {
            val parts = HavenBridge.generateKeyPair()?.split(":")
            if (parts == null || parts.size != 2) return@async SignerPairing.NOT_REACHED
            SignerPairing.pair(npub, bunkerUri.trim(), parts[0], parts[1], configStore.activeAccountHexPubkey.value, pairingStore)
        }.await()

    /**
     * Finishes a nostrconnect:// pairing for [npub], an account already here
     * (iOS ConnectSignerSheetView.pairWithClave): stored like a pasted bunker
     * link, with the pairing's own client key. Returns the message to show,
     * or null once stored.
     */
    suspend fun pairNostrConnectFor(npub: String, request: NIP46Service.NostrConnectRequest, signerPubkey: String): String? =
        viewModelScope.async {
            SignerPairing.pair(
                npub,
                NIP46Service.bunkerUri(signerPubkey, request.relays),
                request.clientSecretKey,
                request.clientPubkey,
                configStore.activeAccountHexPubkey.value,
                pairingStore,
            )
        }.await()

    private val pairingStore = SignerPairing.Store(configStore::setBunkerConfig, configStore::setSigningMode)

    /** Bumped when a key is removed: [hasLocalKey] reads the credential store, not config. */
    private val _keysChanged = kotlinx.coroutines.flow.MutableStateFlow(0)
    val keysChanged: StateFlow<Int> = _keysChanged

    /**
     * Deletes the private key stored on this device for [npub], as iOS
     * "Remove Local Key" does. With a remote signer, signing falls back to it;
     * without one nothing here can sign for the account (browse-only).
     */
    fun removeLocalKey(npub: String) {
        val cfg = config.value
        val hex = hexFor(npub)
        if (npub == cfg.ownerNpub) {
            configStore.update { it.copy(ownerHexKey = null, ownerNcryptsec = null) }
            credentialStore.deleteKeychainPassword(npub)
        } else {
            credentialStore.deleteCredentialHexKey(npub)
        }
        if (hex.isNotEmpty()) credentialStore.deleteNsec(hex)
        if (cfg.signingMode(npub) == "local" && cfg.bunkerConfig(npub) != null) {
            configStore.setSigningMode(npub, "nip46")
        }
        _keysChanged.value++
    }

    fun disconnectSigner(npub: String) {
        // Closes this account's signer session (and detaches it if active),
        // not whichever account's session happens to be active.
        configStore.removeBunkerConfig(npub)
        configStore.setSigningMode(npub, "local")
    }

    fun setSigningMode(npub: String, mode: String) = configStore.setSigningMode(npub, mode)

    fun removeAccount(npub: String) = configStore.removeAccount(npub)

    fun togglePublishRelayList(npub: String, enabled: Boolean) {
        configStore.setPublishRelayList(npub, enabled)
        if (enabled) nostrService.publishRelayList(npub)
    }

    /** Resolve the nsec for an account (call only after biometric auth). */
    fun revealNsec(npub: String): String? {
        val cfg = config.value
        val hexKey = if (npub == cfg.ownerNpub) {
            cfg.ownerHexKey
                ?: cfg.ownerNcryptsec?.let { nc ->
                    val pw = credentialStore.getKeychainPassword(npub) ?: return@let null
                    com.nostrvault.service.NIP49Service.decrypt(nc, pw)
                }
                ?: hexFor(npub).takeIf { it.isNotEmpty() }?.let { credentialStore.getNsec(it) }
        } else {
            credentialStore.getCredentialHexKey(npub)
                ?: hexFor(npub).takeIf { it.isNotEmpty() }?.let { credentialStore.getNsec(it) }
        } ?: return null
        return HavenBridge.encodeNsec(hexKey)
    }
}

/**
 * Import Private Key's password rules, same as setup's "I already use Nostr":
 * an nsec gets a new password (8 characters, typed twice) when [newPassword]
 * (the Vault's own account, which is kept NIP-49 encrypted); an ncryptsec's
 * password already exists and only has to unlock it.
 */
internal fun importKeyProblem(
    input: IdentityInput,
    password: String,
    confirm: String,
    newPassword: Boolean,
): String? = when (input) {
    is IdentityInput.SecretKey -> when {
        !newPassword -> null
        password.length < 8 -> "Password must be at least 8 characters"
        password != confirm -> "Passwords do not match"
        else -> null
    }
    is IdentityInput.EncryptedSecretKey -> if (password.isEmpty()) "Enter the password for this key" else null
    else -> "Paste an nsec1… or ncryptsec1… key."
}
