package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NIP46Service
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URL

    fun SetupWizardViewModel.advanceFromAccount() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                if (_setupPath.value == SetupPath.BROWSE) {
                    // Browse mode: npub, NIP-05, or nprofile
                    var input = _npubInput.value.trim()
                    // Strip nostr: prefix
                    if (input.startsWith("nostr:")) input = input.removePrefix("nostr:")

                    val resolvedNpub: String = when {
                        input.startsWith("npub1") -> {
                            // Validate npub
                            if (HavenBridge.decodeNpub(input) == null) {
                                _error.value = "Invalid npub key"
                                _isLoading.value = false
                                return@launch
                            }
                            input
                        }
                        input.startsWith("nprofile1") -> {
                            // Decode nprofile to get pubkey
                            val profileJson = HavenBridge.decodeNprofile(input)
                            if (profileJson == null) {
                                _error.value = "Invalid nprofile"
                                _isLoading.value = false
                                return@launch
                            }
                            val pubkey = JSONObject(profileJson).getString("pubkey")
                            HavenBridge.hexToNpub(pubkey) ?: run {
                                _error.value = "Failed to encode public key"
                                _isLoading.value = false
                                return@launch
                            }
                        }
                        input.contains("@") || (!input.startsWith("npub") && input.contains(".")) -> {
                            // NIP-05 resolution
                            val resolved = resolveNIP05(input)
                            if (resolved == null) {
                                _isLoading.value = false
                                return@launch // error already set
                            }
                            resolved
                        }
                        else -> {
                            _error.value = "Enter an npub or NIP-05 (user@domain.com)"
                            _isLoading.value = false
                            return@launch
                        }
                    }

                    configStore.update { it.copy(
                        ownerNpub = resolvedNpub,
                        setupMode = "browse",
                        signingMode = "browse",
                    ) }
                    _step.value = stepAfter(WizardStep.ACCOUNT)
                } else {
                    // Full mode
                    when (_accountMode.value) {
                        AccountMode.GENERATE -> {
                            val (npub, skHex, pkHex) = generateAndSaveKeypair() ?: run {
                                _isLoading.value = false
                                return@launch
                            }
                            configStore.update { it.copy(
                                ownerNpub = npub,
                                ownerHexKey = skHex,
                                signingMode = "local",
                                setupMode = "full",
                            ) }
                            configStore.setActiveAccount(pkHex)
                        }
                        AccountMode.IMPORT -> {
                            val nsec = _nsecInput.value.trim()
                            if (!nsec.startsWith("nsec1")) {
                                _error.value = "Key must start with nsec1"
                                _isLoading.value = false
                                return@launch
                            }
                            val skHex = HavenBridge.nsecToHex(nsec)
                            if (skHex == null) {
                                _error.value = "Invalid nsec key"
                                _isLoading.value = false
                                return@launch
                            }
                            val pkHex = HavenBridge.getPublicKey(skHex)
                            if (pkHex == null) {
                                _error.value = "Failed to derive public key"
                                _isLoading.value = false
                                return@launch
                            }
                            val npub = HavenBridge.hexToNpub(pkHex)
                            credentialStore.saveNsec(skHex, pkHex)
                            configStore.update { it.copy(
                                ownerNpub = npub ?: pkHex,
                                ownerHexKey = skHex,
                                signingMode = "local",
                                setupMode = "full",
                            ) }
                            configStore.setActiveAccount(pkHex)
                        }
                        AccountMode.AMBER -> {
                            val hexPubkey = amberSignerService.getPublicKey()
                            if (hexPubkey == null) {
                                _error.value = "Amber signing was cancelled or timed out"
                                _isLoading.value = false
                                return@launch
                            }
                            val npub = HavenBridge.hexToNpub(hexPubkey) ?: hexPubkey
                            configStore.update { it.copy(
                                ownerNpub = npub,
                                signingMode = "amber",
                                setupMode = "full",
                                amberSignerPackage = amberSignerService.signerPackage,
                            ) }
                            configStore.setActiveAccount(hexPubkey)
                        }
                        AccountMode.REMOTE_SIGNER -> {
                            // Same connect this app already offered in
                            // Settings -> Accounts, just reachable at the point
                            // where someone actually says who they are. Anyone
                            // whose key lives in a bunker had to pick one of
                            // the other three, finish setup, then go find the
                            // setting.
                            val uri = _bunkerInput.value.trim()
                            if (!uri.startsWith("bunker://")) {
                                _error.value = "Connection string must start with bunker://"
                                _isLoading.value = false
                                return@launch
                            }
                            val keypair = HavenBridge.generateKeyPair()?.split(":")
                            if (keypair == null || keypair.size != 2) {
                                _error.value = "Could not create a client key for the signer"
                                _isLoading.value = false
                                return@launch
                            }
                            if (!connectRemoteSignerOwner(uri, keypair[0], keypair[1])) {
                                _error.value = "Could not reach that signer. Check the string and that the signer is online."
                                _isLoading.value = false
                                return@launch
                            }
                        }
                    }
                    _step.value = stepAfter(WizardStep.ACCOUNT)
                }
            } catch (e: Exception) {
                _error.value = e.message ?: "Setup failed"
            }
            _isLoading.value = false
        }
    }

    /**
     * Connects a remote signer and makes its account the owner. False when the
     * signer could not be reached.
     */
    internal suspend fun SetupWizardViewModel.connectRemoteSignerOwner(uri: String, clientSec: String, clientPub: String): Boolean {
        val signerPubkey = NIP46Service.connect(clientSec, uri) ?: return false
        // The signer is the account now; drop any key pasted before Back.
        forgetWizardKeys(except = null)
        val npub = HavenBridge.hexToNpub(signerPubkey) ?: signerPubkey
        configStore.setBunkerConfig(
            npub,
            AccountBunkerConfig(
                bunkerURI = uri,
                signerPubkey = signerPubkey,
                clientSecretKey = clientSec,
                clientPubkey = clientPub,
            ),
        )
        configStore.update { it.copy(
            ownerNpub = npub,
            signingMode = "nip46",
            setupMode = "full",
        ) }
        configStore.setActiveAccount(signerPubkey)
        return true
    }

    /**
     * Finishes a nostrconnect:// pairing on the account step: stored as a
     * secret-less bunker link with the pairing's own client key, connected,
     * then on to the next step. Returns an error to show, or null.
     */
    suspend fun SetupWizardViewModel.pairNostrConnect(request: NIP46Service.NostrConnectRequest, signerPubkey: String): String? =
        viewModelScope.async {
            _error.value = null
            val ok = connectRemoteSignerOwner(
                NIP46Service.bunkerUri(signerPubkey, request.relays),
                request.clientSecretKey,
                request.clientPubkey,
            )
            if (ok) {
                // From the account step or "I already use Nostr"'s key step.
                _step.value = stepAfter(_step.value)
                null
            } else {
                "Could not connect to the signer. Try again."
            }
        }.await()

    // ── NIP-05 Resolution ─────────────────────────────────────────

    /** Resolve a NIP-05 identifier to an npub. Returns null on failure (error is set). */
    internal suspend fun SetupWizardViewModel.resolveNIP05(input: String): String? = withContext(Dispatchers.IO) {
        try {
            val lowered = input.lowercase().trim()
            val user: String
            val domain: String
            if (lowered.contains("@")) {
                val parts = lowered.split("@", limit = 2)
                if (parts.size != 2 || parts[0].isEmpty() || parts[1].isEmpty()) {
                    _error.value = "Invalid NIP-05 format. Use user@domain.com"
                    return@withContext null
                }
                user = parts[0]
                domain = parts[1]
            } else {
                // Bare domain — implies _@domain
                user = "_"
                domain = lowered
            }

            if (!domain.contains(".")) {
                _error.value = "Invalid NIP-05 format. Use user@domain.com"
                return@withContext null
            }

            val url = URL("https://$domain/.well-known/nostr.json?name=$user")
            val responseText = url.readText()
            val json = JSONObject(responseText)
            val names = json.optJSONObject("names")
            if (names == null) {
                _error.value = "Name not found on that domain"
                return@withContext null
            }

            val hexPubkey = names.optString(user)
            if (hexPubkey.isNullOrEmpty() || hexPubkey.length != 64) {
                _error.value = "Name not found on that domain"
                return@withContext null
            }

            val npub = HavenBridge.hexToNpub(hexPubkey)
            if (npub == null) {
                _error.value = "Server returned an invalid public key"
                return@withContext null
            }

            npub
        } catch (e: Exception) {
            _error.value = "Could not resolve NIP-05: ${e.localizedMessage ?: "Network error"}"
            null
        }
    }

    // ── I already use Nostr ───────────────────────────────────────
