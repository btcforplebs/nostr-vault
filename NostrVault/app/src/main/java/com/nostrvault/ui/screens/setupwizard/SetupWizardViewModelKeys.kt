package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.normalizeExternalBlossomURL
import com.nostrvault.relay.normalizeExternalRelayURL
import com.nostrvault.service.NIP49Service
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

    /** Records that setup stored [pkHex]'s key, unless it was already here. */
    internal fun SetupWizardViewModel.storeWizardKey(skHex: String, pkHex: String) {
        if (credentialStore.getNsec(pkHex) == null) wizardStoredKeys.add(pkHex)
        credentialStore.saveNsec(skHex, pkHex)
    }

    /**
     * Removes keys this run of setup stored, other than [except]: their nsec,
     * their keychain password, and the owner fields when one of them is the
     * owner. Keys that were on the device before setup are never touched.
     */
    internal fun SetupWizardViewModel.forgetWizardKeys(except: String?) {
        val gone = wizardStoredKeys.filter { it != except }
        if (gone.isEmpty()) return
        for (pk in gone) {
            credentialStore.deleteNsec(pk)
            HavenBridge.hexToNpub(pk)?.let { credentialStore.deleteKeychainPassword(it) }
            wizardStoredKeys.remove(pk)
        }
        val ownerHex = HavenBridge.decodeNpub(configStore.config.value.ownerNpub)
        if (ownerHex != null && ownerHex in gone) {
            configStore.update { it.copy(ownerNpub = "", ownerHexKey = null, ownerNcryptsec = null) }
        }
    }

    /** True when the owner is the key New to Nostr generated this run. */
    internal fun SetupWizardViewModel.ownerIsGeneratedKey(): Boolean {
        val generated = generatedPkHex ?: return false
        return HavenBridge.decodeNpub(configStore.config.value.ownerNpub) == generated
    }

    fun SetupWizardViewModel.advanceFromRelayChoice() {
        val external = _useExternalRelay.value
        val relayURL = _externalRelayInput.value.trim()
        val blossomURL = _externalBlossomInput.value.trim()
        if (external) {
            if (normalizeExternalRelayURL(relayURL) == null) {
                _error.value = "Enter a relay app on this phone (ws://127.0.0.1:4869) or your relay's wss:// address"
                return
            }
            if (blossomURL.isNotEmpty() && normalizeExternalBlossomURL(blossomURL) == null) {
                _error.value = "Enter a media server address on this phone (http://127.0.0.1:port) or an https:// address"
                return
            }
        }
        _error.value = null
        // Saved before setup completes, so MainActivity reads it the first
        // time it would otherwise boot the built-in relay.
        configStore.update {
            if (external) {
                it.copy(useExternalRelay = true, externalRelayURL = relayURL, externalBlossomURL = blossomURL)
            } else {
                it.copy(useExternalRelay = false)
            }
        }
        _step.value = stepAfter(WizardStep.RELAY_CHOICE)
    }

    // ── Key Generation Helper ─────────────────────────────────────

    /** Generate a new keypair and save credentials. Returns (npub, skHex, pkHex) or null on failure. */
    internal fun SetupWizardViewModel.generateAndSaveKeypair(): Triple<String, String, String>? {
        val keypair = HavenBridge.generateKeypair() ?: run {
            _error.value = "Key generation failed"
            return null
        }
        val parts = keypair.split(":")
        if (parts.size != 2) {
            _error.value = "Key generation returned invalid format"
            return null
        }
        val skHex = parts[0]
        val pkHex = parts[1]
        val npub = HavenBridge.hexToNpub(pkHex)
        val nsec = HavenBridge.encodeNsec(skHex)
        _generatedNsec.value = nsec
        storeWizardKey(skHex, pkHex)
        return Triple(npub ?: pkHex, skHex, pkHex)
    }

    // ── New to Nostr ──────────────────────────────────────────────

    /** Generate keys for a new user. Stays on NOSTR_INTRO to show nsec backup. */
    fun SetupWizardViewModel.generateNewUserKeys() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val (npub, skHex, pkHex) = generateAndSaveKeypair() ?: run {
                    _isLoading.value = false
                    return@launch
                }
                _generatedSkHex.value = skHex
                _generatedNpub.value = npub
                generatedPkHex = pkHex
                configStore.update { it.copy(
                    ownerNpub = npub,
                    ownerHexKey = skHex,
                    signingMode = "local",
                    setupMode = "newuser",
                    // The Fill your feed guide opens on top and fills
                    // Following. Popular is the unfiltered feed, so not a
                    // first feed. Same as iOS.
                    defaultFeedMode = "FOLLOWING",
                    blossomMirrors = it.blossomMirrors.ifEmpty { RelayConfiguration.newAccountBlossomMirrors },
                ) }
                configStore.setActiveAccount(pkHex)
                // Stay on NOSTR_INTRO so user can see/copy their nsec
            } catch (e: Exception) {
                _error.value = e.message ?: "Setup failed"
            }
            _isLoading.value = false
        }
    }

    /** Keys page → password page, once they've ticked that the nsec is saved. */
    fun SetupWizardViewModel.advanceFromNostrIntro() {
        _error.value = null
        _step.value = stepAfter(WizardStep.NOSTR_INTRO)
    }

    /** Password page: encrypts the new key with it (NIP-49), then the profile. */
    fun SetupWizardViewModel.advanceFromKeyPassword() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null

            try {
                // Validate password
                if (_passphrase.value.isEmpty()) {
                    _error.value = "Password is required"
                    _isLoading.value = false
                    return@launch
                }
                if (_passphrase.value.length < 8) {
                    _error.value = "Password must be at least 8 characters"
                    _isLoading.value = false
                    return@launch
                }
                if (_passphrase.value != _confirmPassphrase.value) {
                    _error.value = "Passwords do not match"
                    _isLoading.value = false
                    return@launch
                }

                // Encrypt the generated key with NIP-49
                val skHex = _generatedSkHex.value
                if (skHex == null || !ownerIsGeneratedKey()) {
                    _error.value = "Something changed since your key was made. Go back to the start and create it again."
                    _isLoading.value = false
                    return@launch
                }

                val ncryptsec = NIP49Service.encrypt(skHex, _passphrase.value)
                configStore.update { it.copy(ownerNcryptsec = ncryptsec) }
                credentialStore.storeKeychainPassword(
                    password = _passphrase.value,
                    npub = configStore.config.value.ownerNpub,
                )

                _step.value = stepAfter(WizardStep.KEY_PASSWORD)
            } catch (e: Exception) {
                _error.value = e.message ?: "Encryption failed"
            }
            _isLoading.value = false
        }
    }

    // ── Profile (new account) ─────────────────────────────────────
