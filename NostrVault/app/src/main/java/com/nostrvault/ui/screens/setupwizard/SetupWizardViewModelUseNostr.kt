package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NIP49Service
import com.nostrvault.setup.IdentityInput
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

    fun SetupWizardViewModel.setUseNostrInput(value: String) {
        _useNostrInput.value = value
        _useNostrPassword.value = ""
        _useNostrConfirm.value = ""
        _error.value = null
    }
    fun SetupWizardViewModel.setUseNostrPassword(value: String) { _useNostrPassword.value = value; _error.value = null }
    fun SetupWizardViewModel.setUseNostrConfirm(value: String) { _useNostrConfirm.value = value; _error.value = null }

    /**
     * A pasted nsec gets a new password, so the same rules as New to Nostr's
     * password page: 8 characters and typed twice. An ncryptsec's password
     * already exists and only has to unlock it.
     */
    fun SetupWizardViewModel.useNostrPasswordProblem(input: IdentityInput): String? {
        val password = _useNostrPassword.value
        return when (input) {
            is IdentityInput.SecretKey -> when {
                password.length < 8 -> "Password must be at least 8 characters"
                password != _useNostrConfirm.value -> "Passwords do not match"
                else -> null
            }
            is IdentityInput.EncryptedSecretKey -> if (password.isEmpty()) "Enter the password for this key" else null
            else -> null
        }
    }

    /**
     * Whether a pasted key is complete: a one-character typo is a different,
     * valid-looking key, so the checksum is checked before Continue.
     */
    fun SetupWizardViewModel.keyChecksumOK(input: IdentityInput): Boolean = when (input) {
        is IdentityInput.PublicKey -> HavenBridge.decodeNpub(input.key) != null
        is IdentityInput.SecretKey -> HavenBridge.nsecToHex(input.key) != null
        else -> true
    }

    /**
     * The key step's Continue. What was pasted decides the account: a public
     * key or name@domain is read-only, a private key, encrypted key or
     * bunker:// link can post. Same as iOS `UseNostrKeyStep.handleContinue`.
     */
    fun SetupWizardViewModel.continueUseNostr() {
        val input = IdentityInput.parse(_useNostrInput.value)
        val password = _useNostrPassword.value
        useNostrPasswordProblem(input)?.let { _error.value = it; return }
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val ok = when (input) {
                    is IdentityInput.PublicKey -> adoptReadOnly(input.key)
                    is IdentityInput.Nip05 -> {
                        val npub = resolveNIP05(input.name)
                        if (npub == null) {
                            _error.value = "Couldn't find ${input.name}. Check the spelling, or paste your npub."
                            false
                        } else adoptReadOnly(npub)
                    }
                    is IdentityInput.SecretKey -> {
                        val skHex = HavenBridge.nsecToHex(input.key)
                        if (skHex == null) { _error.value = "That key doesn't look complete."; false }
                        else adoptSecretKey(skHex, password, ncryptsec = null)
                    }
                    is IdentityInput.EncryptedSecretKey -> {
                        val skHex = withContext(Dispatchers.IO) {
                            runCatching { NIP49Service.decrypt(input.key, password) }.getOrNull()
                        }
                        if (skHex == null) { _error.value = "That password didn't unlock the key."; false }
                        else adoptSecretKey(skHex, password, ncryptsec = input.key)
                    }
                    is IdentityInput.RemoteSigner -> {
                        val keypair = HavenBridge.generateKeyPair()?.split(":")
                        if (keypair == null || keypair.size != 2) {
                            _error.value = "Could not create a client key for the signer"
                            false
                        } else if (!connectRemoteSignerOwner(input.uri.trim(), keypair[0], keypair[1])) {
                            _error.value = "Couldn't connect to the signer. Check the link and that the signer is online."
                            false
                        } else true
                    }
                    else -> false
                }
                if (ok) _step.value = stepAfter(WizardStep.USE_NOSTR_KEY)
            } catch (e: Exception) {
                _error.value = e.message ?: "Setup failed"
            }
            _isLoading.value = false
        }
    }

    /** Amber (NIP-55), the signer app most Android users already have. */
    fun SetupWizardViewModel.useAmberForUseNostr() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            val hexPubkey = amberSignerService.getPublicKey()
            if (hexPubkey == null) {
                _error.value = "Amber signing was cancelled or timed out"
            } else {
                forgetWizardKeys(except = null)
                configStore.update { it.copy(
                    ownerNpub = HavenBridge.hexToNpub(hexPubkey) ?: hexPubkey,
                    ownerHexKey = null,
                    ownerNcryptsec = null,
                    signingMode = "amber",
                    setupMode = "full",
                    amberSignerPackage = amberSignerService.signerPackage,
                ) }
                configStore.setActiveAccount(hexPubkey)
                _step.value = stepAfter(WizardStep.USE_NOSTR_KEY)
            }
            _isLoading.value = false
        }
    }

    /** Read-only: an npub, as Browse stores it. */
    private fun SetupWizardViewModel.adoptReadOnly(npub: String): Boolean {
        // Clear a key pasted before Back, so it can't stay behind for this account.
        forgetWizardKeys(except = null)
        configStore.update { it.copy(
            ownerNpub = npub, ownerHexKey = null, ownerNcryptsec = null, setupMode = "browse", signingMode = "browse",
        ) }
        HavenBridge.decodeNpub(npub)?.let { configStore.setActiveAccount(it) }
        return true
    }

    /**
     * Can post: the key is stored as New to Nostr stores a generated one,
     * encrypted with [password] (NIP-49) and the password kept in the
     * keystore. [ncryptsec] is the pasted encrypted key, kept as it was.
     */
    private suspend fun SetupWizardViewModel.adoptSecretKey(skHex: String, password: String, ncryptsec: String?): Boolean {
        if (password.isEmpty()) { _error.value = "Enter a password"; return false }
        val pkHex = HavenBridge.getPublicKey(skHex)
        if (pkHex == null) { _error.value = "Failed to derive public key"; return false }
        val npub = HavenBridge.hexToNpub(pkHex) ?: pkHex
        val encrypted = ncryptsec ?: withContext(Dispatchers.IO) { NIP49Service.encrypt(skHex, password) }
        forgetWizardKeys(except = pkHex)
        storeWizardKey(skHex, pkHex)
        configStore.update { it.copy(
            ownerNpub = npub,
            ownerHexKey = skHex,
            ownerNcryptsec = encrypted,
            signingMode = "local",
            setupMode = "full",
        ) }
        credentialStore.storeKeychainPassword(password = password, npub = npub)
        configStore.setActiveAccount(pkHex)
        return true
    }

    /** "browse" when "I already use Nostr" was given only a public key. */
    fun SetupWizardViewModel.setupModeNow(): String = configStore.config.value.setupMode

    // ── Relay check ───────────────────────────────────────────────
