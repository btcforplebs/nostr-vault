package com.nostrvault.ui.screens

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.model.StarterPacksData
import com.nostrvault.R
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.normalizeExternalBlossomURL
import com.nostrvault.relay.normalizeExternalRelayURL
import com.nostrvault.service.AmberSignerService
import com.nostrvault.service.NIP46Service
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.service.BlossomService
import com.nostrvault.service.NIP49Service
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.URL
import javax.inject.Inject

/**
 * Setup wizard for first-run onboarding.
 * Full mode:   Welcome → Path → Account → Relays → Import → Media → Wallet → Complete
 * Browse mode: Welcome → Path → Account → Complete
 * Port of SetupWizardView.swift.
 */

// ── Wizard colors (from iOS WizardColors) ────────────────────────

private val WizardBgPrimary = Color(0xFF09090B)
private val WizardBgCard = Color(0xFF18181B)
private val WizardBgElevated = Color(0xFF27272A)
private val WizardBorderSubtle = Color.White.copy(alpha = 0.06f)
private val WizardBorderActive = Color(0xFFF59E0B).copy(alpha = 0.4f)
private val WizardAccent = Color(0xFFF59E0B)
private val WizardGradient = Brush.horizontalGradient(
    colors = listOf(Color(0xFFEA580C), Color(0xFFF59E0B)),
)

// ── Enums ────────────────────────────────────────────────────────

enum class WizardStep {
    WELCOME, CHOOSE_PATH, RELAY_CHOICE, NOSTR_INTRO, INITIAL_FOLLOWS, ACCOUNT, RELAYS, IMPORT_NOTES, MIRROR_MEDIA, WALLET, COMPLETE
}

enum class AccountMode { GENERATE, IMPORT, AMBER, REMOTE_SIGNER }
enum class SetupPath { NONE, FULL, BROWSE, NEW_TO_NOSTR }

// ── ViewModel ────────────────────────────────────────────────────

@HiltViewModel
class SetupWizardViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val amberSignerService: AmberSignerService,
    private val blossomService: BlossomService,
    private val nostrService: NostrService,
    @ApplicationContext private val appContext: Context,
) : ViewModel() {

    // Navigation
    private val _step = MutableStateFlow(WizardStep.WELCOME)
    val step = _step.asStateFlow()

    private val _setupPath = MutableStateFlow(SetupPath.NONE)
    val setupPath = _setupPath.asStateFlow()

    // Relay choice: the built-in relay, or a relay app already on the phone
    private val _useExternalRelay = MutableStateFlow(false)
    val useExternalRelay = _useExternalRelay.asStateFlow()

    private val _externalRelayInput = MutableStateFlow("")
    val externalRelayInput = _externalRelayInput.asStateFlow()

    private val _externalBlossomInput = MutableStateFlow("")
    val externalBlossomInput = _externalBlossomInput.asStateFlow()

    // Account
    private val _accountMode = MutableStateFlow(AccountMode.GENERATE)
    val accountMode = _accountMode.asStateFlow()

    private val _npubInput = MutableStateFlow("")
    val npubInput = _npubInput.asStateFlow()

    private val _nsecInput = MutableStateFlow("")
    val nsecInput = _nsecInput.asStateFlow()

    private val _bunkerInput = MutableStateFlow("")
    val bunkerInput = _bunkerInput.asStateFlow()

    private val _passphrase = MutableStateFlow("")
    val passphrase = _passphrase.asStateFlow()

    private val _confirmPassphrase = MutableStateFlow("")
    val confirmPassphrase = _confirmPassphrase.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _generatedNsec = MutableStateFlow<String?>(null)
    val generatedNsec = _generatedNsec.asStateFlow()

    private val _generatedSkHex = MutableStateFlow<String?>(null)

    private val _isAmberAvailable = MutableStateFlow(false)
    val isAmberAvailable = _isAmberAvailable.asStateFlow()

    // Relays
    private val _wizardRelays = MutableStateFlow(
        listOf(
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.mom",
            "wss://relay.btcforplebs.com",
            "wss://nostr-pub.wellorder.net",
        )
    )
    val wizardRelays = _wizardRelays.asStateFlow()

    private val _newRelayInput = MutableStateFlow("")
    val newRelayInput = _newRelayInput.asStateFlow()

    private val _macRelayInput = MutableStateFlow("")
    val macRelayInput = _macRelayInput.asStateFlow()

    // Import
    private val _importStartDate = MutableStateFlow("2023-01-01")
    val importStartDate = _importStartDate.asStateFlow()

    private val _isImporting = MutableStateFlow(false)
    val isImporting = _isImporting.asStateFlow()

    private val _importProgress = MutableStateFlow(-1f) // -1 = indeterminate
    val importProgress = _importProgress.asStateFlow()

    private val _importStatus = MutableStateFlow("")
    val importStatus = _importStatus.asStateFlow()

    private val _importCompleted = MutableStateFlow(false)
    val importCompleted = _importCompleted.asStateFlow()

    // Blossom
    private val _blossomURL = MutableStateFlow("https://blossom.primal.net")
    val blossomURL = _blossomURL.asStateFlow()

    private val _isMirroring = MutableStateFlow(false)
    val isMirroring = _isMirroring.asStateFlow()

    private val _mirrorProgress = MutableStateFlow(-1f)
    val mirrorProgress = _mirrorProgress.asStateFlow()

    private val _mirrorStatus = MutableStateFlow("")
    val mirrorStatus = _mirrorStatus.asStateFlow()

    private val _mirrorCompleted = MutableStateFlow(false)
    val mirrorCompleted = _mirrorCompleted.asStateFlow()

    // Wallet
    private val _nwcInput = MutableStateFlow("")
    val nwcInput = _nwcInput.asStateFlow()


    // Starter Packs
    private val _starterPacks = MutableStateFlow<StarterPacksData?>(null)
    val starterPacks = _starterPacks.asStateFlow()

    private val _selectedNpubs = MutableStateFlow<Set<String>>(emptySet())
    val selectedNpubs = _selectedNpubs.asStateFlow()

    private val _expandedPackId = MutableStateFlow<String?>(null)
    val expandedPackId = _expandedPackId.asStateFlow()

    init {
        _isAmberAvailable.value = amberSignerService.isAmberInstalled()
        loadStarterPacks()
    }

    // ── Setters ──────────────────────────────────────────────────

    fun setSetupPath(path: SetupPath) { _setupPath.value = path }
    fun setUseExternalRelay(value: Boolean) { _useExternalRelay.value = value }
    fun setExternalRelayInput(value: String) { _externalRelayInput.value = value }
    fun setExternalBlossomInput(value: String) { _externalBlossomInput.value = value }
    fun setAccountMode(mode: AccountMode) { _accountMode.value = mode }
    fun setNpubInput(value: String) { _npubInput.value = value; _error.value = null }
    fun setNsecInput(value: String) { _nsecInput.value = value; _error.value = null }

    fun setBunkerInput(value: String) { _bunkerInput.value = value; _error.value = null }
    fun setPassphrase(value: String) { _passphrase.value = value }
    fun setConfirmPassphrase(value: String) { _confirmPassphrase.value = value }
    fun setNewRelayInput(value: String) { _newRelayInput.value = value }
    fun setMacRelayInput(value: String) { _macRelayInput.value = value }
    fun setImportStartDate(value: String) { _importStartDate.value = value }
    fun setBlossomURL(value: String) { _blossomURL.value = value }
    fun setNwcInput(value: String) { _nwcInput.value = value }

    // ── Navigation ───────────────────────────────────────────────

    /** Steps for full setup mode. */
    private val fullSteps = listOf(
        WizardStep.WELCOME, WizardStep.CHOOSE_PATH, WizardStep.RELAY_CHOICE, WizardStep.ACCOUNT,
        WizardStep.RELAYS, WizardStep.IMPORT_NOTES, WizardStep.MIRROR_MEDIA,
        WizardStep.WALLET, WizardStep.COMPLETE,
    )

    /** Steps for browse mode. */
    private val browseSteps = listOf(
        WizardStep.WELCOME, WizardStep.CHOOSE_PATH, WizardStep.RELAY_CHOICE, WizardStep.ACCOUNT,
        WizardStep.IMPORT_NOTES, WizardStep.COMPLETE,
    )

    /** Steps for "New to Nostr" mode. */
    private val newUserSteps = listOf(
        WizardStep.WELCOME, WizardStep.CHOOSE_PATH, WizardStep.RELAY_CHOICE,
        WizardStep.NOSTR_INTRO, WizardStep.INITIAL_FOLLOWS, WizardStep.COMPLETE,
    )

    /**
     * Active step list based on current setup path. Importing notes and
     * syncing media both fill the built-in relay, so an external relay
     * skips them and the built-in relay never runs during setup.
     */
    val activeSteps: List<WizardStep>
        get() {
            val steps = when (_setupPath.value) {
                SetupPath.BROWSE -> browseSteps
                SetupPath.NEW_TO_NOSTR -> newUserSteps
                else -> fullSteps
            }
            return if (_useExternalRelay.value) {
                steps - WizardStep.IMPORT_NOTES - WizardStep.MIRROR_MEDIA
            } else {
                steps
            }
        }

    /** The step that follows [step] on the active path. */
    private fun stepAfter(step: WizardStep): WizardStep {
        val steps = activeSteps
        return steps.getOrNull(steps.indexOf(step) + 1) ?: WizardStep.COMPLETE
    }

    /** Current step index (0-based) within active step list. */
    val currentStepIndex: Int
        get() = activeSteps.indexOf(_step.value).coerceAtLeast(0)

    fun goBack() {
        val steps = activeSteps
        val idx = steps.indexOf(_step.value)
        if (idx > 0) _step.value = steps[idx - 1]
    }

    fun advanceFromWelcome() { _step.value = WizardStep.CHOOSE_PATH }

    fun advanceFromChoosePath() { _step.value = WizardStep.RELAY_CHOICE }

    fun advanceFromRelayChoice() {
        val external = _useExternalRelay.value
        val relayURL = _externalRelayInput.value.trim()
        val blossomURL = _externalBlossomInput.value.trim()
        if (external) {
            if (normalizeExternalRelayURL(relayURL) == null) {
                _error.value = "Enter the relay app's address on this phone, e.g. ws://127.0.0.1:4869"
                return
            }
            if (blossomURL.isNotEmpty() && normalizeExternalBlossomURL(blossomURL) == null) {
                _error.value = "Enter the Blossom address on this phone, e.g. http://127.0.0.1:port"
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
    private fun generateAndSaveKeypair(): Triple<String, String, String>? {
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
        credentialStore.saveNsec(skHex, pkHex)
        return Triple(npub ?: pkHex, skHex, pkHex)
    }

    // ── New to Nostr ──────────────────────────────────────────────

    /** Generate keys for a new user. Stays on NOSTR_INTRO to show nsec backup. */
    fun generateNewUserKeys() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val (npub, skHex, pkHex) = generateAndSaveKeypair() ?: run {
                    _isLoading.value = false
                    return@launch
                }
                _generatedSkHex.value = skHex
                configStore.update { it.copy(
                    ownerNpub = npub,
                    ownerHexKey = skHex,
                    signingMode = "local",
                    setupMode = "newuser",
                    defaultFeedMode = "POPULAR",
                ) }
                configStore.setActiveAccount(pkHex)
                // Stay on NOSTR_INTRO so user can see/copy their nsec
            } catch (e: Exception) {
                _error.value = e.message ?: "Setup failed"
            }
            _isLoading.value = false
        }
    }

    /** Advance from NOSTR_INTRO to COMPLETE after user has seen their nsec. */
    fun advanceFromNostrIntro() {
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
                if (skHex == null) {
                    _error.value = "No key generated"
                    _isLoading.value = false
                    return@launch
                }

                val ncryptsec = NIP49Service.encrypt(skHex, _passphrase.value)
                configStore.update { it.copy(ownerNcryptsec = ncryptsec) }
                credentialStore.storeKeychainPassword(configStore.config.value.ownerNpub, _passphrase.value)

                _step.value = WizardStep.INITIAL_FOLLOWS
            } catch (e: Exception) {
                _error.value = e.message ?: "Encryption failed"
            }
            _isLoading.value = false
        }
    }

    // ── Account ───────────────────────────────────────────────────

    fun advanceFromAccount() {
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
                            val signerPubkey = NIP46Service.connect(keypair[0], uri)
                            if (signerPubkey == null) {
                                _error.value = "Could not reach that signer. Check the string and that the signer is online."
                                _isLoading.value = false
                                return@launch
                            }
                            val npub = HavenBridge.hexToNpub(signerPubkey) ?: signerPubkey
                            configStore.setBunkerConfig(
                                npub,
                                AccountBunkerConfig(
                                    bunkerURI = uri,
                                    signerPubkey = signerPubkey,
                                    clientSecretKey = keypair[0],
                                    clientPubkey = keypair[1],
                                ),
                            )
                            configStore.update { it.copy(
                                ownerNpub = npub,
                                signingMode = "nip46",
                                setupMode = "full",
                            ) }
                            configStore.setActiveAccount(signerPubkey)
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

    // ── NIP-05 Resolution ─────────────────────────────────────────

    /** Resolve a NIP-05 identifier to an npub. Returns null on failure (error is set). */
    private suspend fun resolveNIP05(input: String): String? = withContext(Dispatchers.IO) {
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

    // ── Relays ───────────────────────────────────────────────────

    fun addWizardRelay() {
        val url = _newRelayInput.value.trim()
        if (url.isBlank() || !url.startsWith("wss://")) return
        if (url in _wizardRelays.value) return
        _wizardRelays.value = _wizardRelays.value + url
        _newRelayInput.value = ""
    }

    fun removeWizardRelay(url: String) {
        _wizardRelays.value = _wizardRelays.value - url
    }

    fun advanceFromRelays() {
        configStore.update { it.copy(
            inboxRelays = _wizardRelays.value,
            feedRelays = _wizardRelays.value,
            macRelayURL = _macRelayInput.value.trim(),
        ) }
        _step.value = stepAfter(WizardStep.RELAYS)
    }

    // ── Import ───────────────────────────────────────────────────

    fun startNetworkImport() {
        if (_isImporting.value) return
        viewModelScope.launch {
            // Persist the selected import start date to config
            configStore.update { it.copy(importStartDate = _importStartDate.value) }

            _isImporting.value = true
            _importProgress.value = -1f
            _importStatus.value = "Setting up import..."
            _importCompleted.value = false

            // Poll Go relay logs in the background so the UI shows progress
            val pollJob = launch(Dispatchers.Default) {
                while (true) {
                    try {
                        val logLine = HavenBridge.getImportLog()
                        if (logLine != null) {
                            _importStatus.value = logLine
                        }
                    } catch (_: Exception) { }
                    kotlinx.coroutines.delay(400)
                }
            }

            withContext(Dispatchers.IO) {
                try {
                    if (!HavenBridge.isLoaded) {
                        _importStatus.value = "Native library not loaded"
                        _isImporting.value = false
                        return@withContext
                    }

                    val relayDataDir = File(appContext.filesDir, "relay_data")
                    RelayConfiguration.ensureDirectories(relayDataDir)

                    val config = configStore.config.value
                    val envDict = RelayConfiguration.generateEnvDictionary(
                        config = config,
                        relayDataDir = relayDataDir,
                    )
                    for ((key, value) in envDict) {
                        HavenBridge.setEnv(key, value)
                    }

                    // Write seed relays JSON and set env to ABSOLUTE path
                    val seedRelaysFile = File(relayDataDir, "relays_import.json")
                    val seedRelays = config.importSeedRelays
                    val relaysJson = buildString {
                        append("[")
                        append(seedRelays.joinToString(",") { "\"$it\"" })
                        append("]")
                    }
                    seedRelaysFile.writeText(relaysJson)
                    HavenBridge.setEnv("IMPORT_SEED_RELAYS_FILE", seedRelaysFile.absolutePath)

                    // Also fix other file-based env vars that need absolute paths
                    val blastrFile = File(relayDataDir, config.blastrRelaysFile)
                    if (!blastrFile.exists()) {
                        val blastrJson = buildString {
                            append("[")
                            append(config.blastrRelays.joinToString(",") { "\"$it\"" })
                            append("]")
                        }
                        blastrFile.writeText(blastrJson)
                    }
                    HavenBridge.setEnv("BLASTR_RELAYS_FILE", blastrFile.absolutePath)

                    // Ensure import start date is set
                    val startDate = config.importStartDate.ifEmpty { "2023-01-01" }
                    HavenBridge.setEnv("IMPORT_START_DATE", startDate)

                    // startRelay(importMode = true) is blocking -- pollJob
                    // feeds Go log output to _importStatus while this runs
                    HavenBridge.startRelay(importMode = true)

                    _importCompleted.value = true
                    _importStatus.value = "Import complete"
                } catch (e: Exception) {
                    _importStatus.value = "Import failed: ${e.message}"
                }
                _isImporting.value = false
            }

            pollJob.cancel()
        }
    }

    fun restoreFromBackup(zipPath: String) {
        if (_isImporting.value) return
        viewModelScope.launch {
            _isImporting.value = true
            _importStatus.value = "Restoring from backup..."
            _importCompleted.value = false

            withContext(Dispatchers.IO) {
                try {
                    val result = HavenBridge.restoreDatabase(zipPath)
                    if (result == 0) {
                        _importCompleted.value = true
                        _importStatus.value = "Restore complete"
                    } else {
                        _importStatus.value = "Restore failed (code $result)"
                    }
                } catch (e: Exception) {
                    _importStatus.value = "Restore failed: ${e.message}"
                }
                _isImporting.value = false
            }
        }
    }

    fun cancelImport() {
        viewModelScope.launch(Dispatchers.IO) {
            try { HavenBridge.stopRelay() } catch (_: Exception) {}
        }
    }

    fun advanceFromImport() {
        _step.value = if (_setupPath.value == SetupPath.BROWSE) WizardStep.COMPLETE else WizardStep.MIRROR_MEDIA
    }
    fun skipImport() {
        _step.value = if (_setupPath.value == SetupPath.BROWSE) WizardStep.COMPLETE else WizardStep.MIRROR_MEDIA
    }

    // ── Blossom ──────────────────────────────────────────────────

    fun startMediaMirror() {
        if (_isMirroring.value) return
        viewModelScope.launch {
            _isMirroring.value = true
            _mirrorProgress.value = -1f
            _mirrorStatus.value = "Starting media sync..."
            _mirrorCompleted.value = false

            // Save mirror URL to config first
            val url = _blossomURL.value.trim()
            if (url.isNotEmpty()) {
                configStore.update { config ->
                    if (url !in config.blossomMirrors) {
                        config.copy(blossomMirrors = config.blossomMirrors + url)
                    } else config
                }
            }

            try {
                blossomService.mirrorAllFromExternal(
                    onProgress = { progress ->
                        _mirrorProgress.value = progress
                    },
                    onLogMessage = { message ->
                        _mirrorStatus.value = message
                    },
                )
                _mirrorCompleted.value = true
                _mirrorStatus.value = "Media sync complete"
            } catch (e: Exception) {
                _mirrorStatus.value = "Sync failed: ${e.message}"
            }
            _isMirroring.value = false
        }
    }

    fun importMediaArchive(zipPath: String) {
        if (_isMirroring.value) return
        viewModelScope.launch {
            _isMirroring.value = true
            _mirrorStatus.value = "Extracting media archive..."
            _mirrorCompleted.value = false

            withContext(Dispatchers.IO) {
                try {
                    val relayDataDir = File(appContext.filesDir, "relay_data")
                    val blossomDir = File(relayDataDir, "blossom")
                    blossomDir.mkdirs()
                    val result = HavenBridge.unzipDirectory(zipPath, blossomDir.absolutePath)
                    if (result == 0) {
                        _mirrorCompleted.value = true
                        _mirrorStatus.value = "Media import complete"
                    } else {
                        _mirrorStatus.value = "Import failed (code $result)"
                    }
                } catch (e: Exception) {
                    _mirrorStatus.value = "Import failed: ${e.message}"
                }
                _isMirroring.value = false
            }
        }
    }

    fun advanceFromMedia() { _step.value = WizardStep.WALLET }
    fun skipMedia() { _step.value = WizardStep.WALLET }

    // ── Wallet ───────────────────────────────────────────────────

    fun advanceFromWallet() {
        val nwc = _nwcInput.value.trim().ifEmpty { null }
        configStore.update { it.copy(nwcURI = nwc) }
        _step.value = WizardStep.COMPLETE
    }

    fun skipWallet() { _step.value = WizardStep.COMPLETE }

    // ── Initial Follows ───────────────────────────────────────────

    private val starterPackJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    private fun loadStarterPacks() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val inputStream = appContext.resources.openRawResource(R.raw.starter_packs)
                val json = inputStream.bufferedReader().use { it.readText() }
                val packs = starterPackJson.decodeFromString<StarterPacksData>(json)
                _starterPacks.value = packs
            } catch (e: Exception) {
                android.util.Log.e("SetupWizard", "Failed to load starter packs", e)
            }
        }
    }

    fun toggleAccountSelection(npub: String) {
        val current = _selectedNpubs.value.toMutableSet()
        if (current.contains(npub)) {
            current.remove(npub)
        } else {
            current.add(npub)
        }
        _selectedNpubs.value = current
    }

    fun togglePackExpansion(packId: String) {
        _expandedPackId.value = if (_expandedPackId.value == packId) null else packId
    }

    fun advanceFromInitialFollows() {
        viewModelScope.launch {
            val npubs = _selectedNpubs.value
            if (npubs.isNotEmpty()) {
                // Follow selected accounts
                val config = configStore.config.value
                val currentFollows = (config.whitelistedNpubs ?: emptyList()).toMutableList()
                val newFollows = npubs.filter { it !in currentFollows }
                if (newFollows.isNotEmpty()) {
                    configStore.update { it.copy(whitelistedNpubs = currentFollows + newFollows) }
                }
            }
            _step.value = WizardStep.COMPLETE
        }
    }

    fun skipInitialFollows() {
        _step.value = WizardStep.COMPLETE
    }

    // ── Complete ─────────────────────────────────────────────────

    fun completeSetup(onComplete: () -> Unit) {
        viewModelScope.launch {
            configStore.update { it.copy(hasCompletedSetup = true) }

            // Advertise where to send us DMs. Setup never did this, so a new
            // account had no kind 10050 at all and was effectively unreachable
            // over NIP-17 — senders fell through to a guessed relay set and
            // replies had nowhere defined to go.
            runCatching { nostrService.republishDMRelayList() }

            // Resolve active account hex pubkey (matches iOS refreshActiveAccountHex)
            val npub = configStore.config.value.ownerNpub
            if (npub.startsWith("npub1")) {
                try {
                    val hex = HavenBridge.decodeNpub(npub)
                    if (!hex.isNullOrEmpty()) {
                        configStore.setActiveAccount(hex)
                    }
                } catch (_: Exception) {}
            }

            onComplete()
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Screen
// ══════════════════════════════════════════════════════════════════

@Composable
fun SetupWizardScreen(
    onComplete: () -> Unit,
    viewModel: SetupWizardViewModel = hiltViewModel(),
) {
    val step by viewModel.step.collectAsState()
    val setupPath by viewModel.setupPath.collectAsState()
    val scrollState = rememberScrollState()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(WizardBgPrimary),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(horizontal = 24.dp)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Spacer(Modifier.height(32.dp))

            // Back button (hidden on first step)
            if (step != WizardStep.WELCOME) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Start,
                ) {
                    IconButton(onClick = viewModel::goBack) {
                        Icon(
                            imageVector = NostrVaultIcons.Back,
                            contentDescription = "Back",
                            tint = SecondaryText,
                        )
                    }
                }
            } else {
                Spacer(Modifier.height(48.dp))
            }

            // App brand
            Text(
                text = "Nostr Vault",
                color = WizardAccent,
                fontSize = 32.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Your personal relay",
                color = SecondaryText,
                fontSize = 16.sp,
            )

            // Step dots
            if (step != WizardStep.WELCOME) {
                Spacer(Modifier.height(16.dp))
                StepDots(
                    totalSteps = viewModel.activeSteps.size,
                    currentIndex = viewModel.currentStepIndex,
                )
            }

            Spacer(Modifier.height(32.dp))

            AnimatedContent(
                targetState = step,
                transitionSpec = {
                    (slideInHorizontally(Motion.panel()) { it } + fadeIn(Motion.panel())).togetherWith(
                        slideOutHorizontally(Motion.panel()) { -it } + fadeOut(Motion.panel())
                    )
                },
                label = "wizard_step",
            ) { currentStep ->
                when (currentStep) {
                    WizardStep.WELCOME -> WelcomeStep(
                        onContinue = viewModel::advanceFromWelcome,
                    )
                    WizardStep.CHOOSE_PATH -> ChoosePathStep(viewModel)
                    WizardStep.RELAY_CHOICE -> RelayChoiceStep(viewModel)
                    WizardStep.NOSTR_INTRO -> NostrIntroStep(viewModel)
                    WizardStep.INITIAL_FOLLOWS -> InitialFollowsStep(viewModel)
                    WizardStep.ACCOUNT -> AccountStep(viewModel)
                    WizardStep.RELAYS -> RelayStep(viewModel)
                    WizardStep.IMPORT_NOTES -> ImportNotesStep(viewModel)
                    WizardStep.MIRROR_MEDIA -> MirrorMediaStep(viewModel)
                    WizardStep.WALLET -> WalletSetupStep(viewModel)
                    WizardStep.COMPLETE -> CompleteStep(
                        setupPath = setupPath,
                        onFinish = { viewModel.completeSetup(onComplete) },
                    )
                }
            }

            Spacer(Modifier.height(48.dp))
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step Dots
// ══════════════════════════════════════════════════════════════════

@Composable
private fun StepDots(totalSteps: Int, currentIndex: Int) {
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        for (i in 0 until totalSteps) {
            Box(
                modifier = Modifier
                    .size(if (i == currentIndex) 10.dp else 8.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            i < currentIndex -> WizardAccent.copy(alpha = 0.4f)
                            i == currentIndex -> WizardAccent
                            else -> WizardBorderSubtle
                        }
                    ),
            )
            if (i < totalSteps - 1) {
                Spacer(Modifier.width(8.dp))
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 1: Welcome
// ══════════════════════════════════════════════════════════════════

@Composable
private fun WelcomeStep(onContinue: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        WizardCard {
            Text(
                text = "Take control of your social data",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Nostr Vault runs a personal relay on your device. Your notes, messages, and media stay with you -- not on someone else's server.",
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(24.dp))

        val features = listOf(
            "Personal Relay" to "Run your own relay on-device",
            "Full Nostr Client" to "Browse, post, reply, discover",
            "Private Messaging" to "NIP-17 encrypted DMs",
            "Blossom Media" to "Host images/videos on your device",
            "Lightning Zaps" to "Send and receive zaps with your own wallet over NWC",
        )
        for ((title, desc) in features) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 6.dp),
            ) {
                Text("*", color = WizardAccent, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                    Text(desc, color = SecondaryText, fontSize = 13.sp)
                }
            }
        }

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(text = "Get Started", onClick = onContinue)
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 2: Choose Path
// ══════════════════════════════════════════════════════════════════

@Composable
private fun ChoosePathStep(viewModel: SetupWizardViewModel) {
    val setupPath by viewModel.setupPath.collectAsState()

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Choose your setup",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "You can upgrade from browse mode later.",
            color = SecondaryText,
            fontSize = 14.sp,
        )

        Spacer(Modifier.height(24.dp))

        WizardOptionCard(
            title = "New to Nostr",
            subtitle = "Quick start -- we'll set everything up for you",
            selected = setupPath == SetupPath.NEW_TO_NOSTR,
            onClick = { viewModel.setSetupPath(SetupPath.NEW_TO_NOSTR) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(12.dp))

        WizardOptionCard(
            title = "Full Setup",
            subtitle = "Relay, notes, media, wallet -- the complete package",
            selected = setupPath == SetupPath.FULL,
            onClick = { viewModel.setSetupPath(SetupPath.FULL) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(12.dp))

        WizardOptionCard(
            title = "Browse Mode",
            subtitle = "Read-only browsing -- no private key needed",
            selected = setupPath == SetupPath.BROWSE,
            onClick = { viewModel.setSetupPath(SetupPath.BROWSE) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(
            text = "Continue",
            enabled = setupPath != SetupPath.NONE,
            onClick = viewModel::advanceFromChoosePath,
        )
    }
}

// ══════════════════════════════════════════════════════════════════
// Step: Relay Choice
// ══════════════════════════════════════════════════════════════════

@Composable
private fun RelayChoiceStep(viewModel: SetupWizardViewModel) {
    val useExternal by viewModel.useExternalRelay.collectAsState()
    val relayInput by viewModel.externalRelayInput.collectAsState()
    val blossomInput by viewModel.externalBlossomInput.collectAsState()
    val error by viewModel.error.collectAsState()

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Where should your notes live?",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "You can change this later in Settings > Advanced.",
            color = SecondaryText,
            fontSize = 14.sp,
        )

        Spacer(Modifier.height(24.dp))

        WizardOptionCard(
            title = "Built-in Relay",
            subtitle = "Recommended -- your own relay and media server inside this app",
            selected = !useExternal,
            onClick = { viewModel.setUseExternalRelay(false) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(12.dp))

        WizardOptionCard(
            title = "A Relay App on This Phone",
            subtitle = "Keep the client and your relay in separate apps, e.g. Citrine. " +
                "The built-in relay never starts.",
            selected = useExternal,
            onClick = { viewModel.setUseExternalRelay(true) },
            modifier = Modifier.fillMaxWidth(),
        )

        if (useExternal) {
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = relayInput,
                onValueChange = viewModel::setExternalRelayInput,
                label = { Text("Relay URL") },
                placeholder = { Text("ws://127.0.0.1:4869") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
                colors = wizardTextFieldColors(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = blossomInput,
                onValueChange = viewModel::setExternalBlossomInput,
                label = { Text("Blossom URL (optional)") },
                placeholder = { Text("http://127.0.0.1:port") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
                colors = wizardTextFieldColors(),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Setup skips importing your notes and media, since those fill the " +
                    "built-in relay. Notifications and the Popular feed need the built-in " +
                    "relay and stay off.",
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(text = it, color = ErrorRed, fontSize = 13.sp)
        }

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(
            text = "Continue",
            onClick = viewModel::advanceFromRelayChoice,
        )
    }
}

// ══════════════════════════════════════════════════════════════════
// Step: Nostr Intro (New to Nostr path)
// ══════════════════════════════════════════════════════════════════

@Composable
private fun NostrIntroStep(viewModel: SetupWizardViewModel) {
    val generatedNsec by viewModel.generatedNsec.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val passphrase by viewModel.passphrase.collectAsState()
    val confirmPassphrase by viewModel.confirmPassphrase.collectAsState()
    val context = LocalContext.current
    var showPassword by remember { mutableStateOf(false) }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // Card 1: What is Nostr
        WizardCard {
            Text(
                text = "Welcome to Nostr",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Nostr is an open social protocol. You own your identity " +
                    "through a cryptographic keypair -- no company controls your " +
                    "account. Your posts are broadcast to relays and can be read " +
                    "by anyone.",
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(16.dp))

        // Card 2: Why Nostr Vault is unique
        WizardCard {
            Text(
                text = "Your Personal Archive",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Nostr Vault runs a HAVEN relay right on your device. " +
                    "Every note, message, and media file you interact with is " +
                    "archived locally. Your data stays with you -- not on " +
                    "someone else's server.",
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(20.dp))

        if (generatedNsec != null) {
            // Card 3: Secret key backup
            WizardCard {
                Text(
                    text = "Your Secret Key",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Save this somewhere safe. It's the only way to recover " +
                        "your account. Anyone with this key can post as you.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = generatedNsec!!,
                    color = WizardAccent,
                    fontSize = 12.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(WizardBgElevated)
                        .border(1.dp, WizardBorderSubtle, RoundedCornerShape(8.dp))
                        .clickable {
                            val clipboard = context.getSystemService(
                                Context.CLIPBOARD_SERVICE,
                            ) as android.content.ClipboardManager
                            clipboard.setPrimaryClip(
                                android.content.ClipData.newPlainText("nsec", generatedNsec),
                            )
                        }
                        .padding(12.dp),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "Tap to copy",
                    color = SecondaryText.copy(alpha = 0.5f),
                    fontSize = 11.sp,
                )
            }

            Spacer(Modifier.height(16.dp))

            // Card 4: Password protection
            WizardCard {
                Text(
                    text = "Protect Your Key",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Set a password to encrypt your private key. You'll need this password to use Haven.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
                Spacer(Modifier.height(12.dp))

                // Password field
                OutlinedTextField(
                    value = passphrase,
                    onValueChange = viewModel::setPassphrase,
                    label = { Text("Password (minimum 8 characters)") },
                    singleLine = true,
                    visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(onClick = { showPassword = !showPassword }) {
                            Icon(
                                imageVector = if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = if (showPassword) "Hide password" else "Show password",
                                tint = WizardAccent,
                            )
                        }
                    },
                    isError = passphrase.isNotEmpty() && passphrase.length < 8,
                    supportingText = if (passphrase.isNotEmpty() && passphrase.length < 8) {
                        { Text("Password must be at least 8 characters", color = ErrorRed) }
                    } else null,
                    colors = wizardTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )

                Spacer(Modifier.height(8.dp))

                // Confirm password field
                OutlinedTextField(
                    value = confirmPassphrase,
                    onValueChange = viewModel::setConfirmPassphrase,
                    label = { Text("Confirm password") },
                    singleLine = true,
                    visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                    isError = confirmPassphrase.isNotEmpty() && passphrase != confirmPassphrase,
                    supportingText = if (confirmPassphrase.isNotEmpty() && passphrase != confirmPassphrase) {
                        { Text("Passwords do not match", color = ErrorRed) }
                    } else null,
                    colors = wizardTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(32.dp))

            val isPasswordValid = passphrase.isNotEmpty() && passphrase.length >= 8 && passphrase == confirmPassphrase
            WizardPrimaryButton(
                text = "Continue",
                enabled = isPasswordValid && !isLoading,
                onClick = viewModel::advanceFromNostrIntro,
            )
        } else {
            // Error display
            error?.let { errorText ->
                Text(errorText, color = Color(0xFFEF4444), fontSize = 13.sp)
                Spacer(Modifier.height(8.dp))
            }

            WizardPrimaryButton(
                text = "Create My Account",
                enabled = !isLoading,
                onClick = viewModel::generateNewUserKeys,
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 3: Account
// ══════════════════════════════════════════════════════════════════

@Composable
private fun AccountStep(viewModel: SetupWizardViewModel) {
    val setupPath by viewModel.setupPath.collectAsState()
    val mode by viewModel.accountMode.collectAsState()
    val npubInput by viewModel.npubInput.collectAsState()
    val nsecInput by viewModel.nsecInput.collectAsState()
    val error by viewModel.error.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val generatedNsec by viewModel.generatedNsec.collectAsState()
    val isAmberAvailable by viewModel.isAmberAvailable.collectAsState()
    val focusManager = LocalFocusManager.current

    val bunkerInput by viewModel.bunkerInput.collectAsState()

    // A bunker string is long and arrives as a QR code from the signer;
    // scanning it is the difference between the option being usable and being
    // theoretical.
    val bunkerScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { viewModel.setBunkerInput(it) }
    }

    // QR scanner launcher
    val qrLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let { scanned ->
            val cleaned = if (scanned.startsWith("nostr:")) scanned.removePrefix("nostr:") else scanned
            viewModel.setNpubInput(cleaned)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = if (setupPath == SetupPath.BROWSE) "Enter your identity" else "Set up your account",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(20.dp))

        if (setupPath == SetupPath.BROWSE) {
            // Browse mode: npub, NIP-05, or QR
            Text(
                text = "Enter your npub, NIP-05 (user@domain), or scan a QR code.",
                color = SecondaryText,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = npubInput,
                onValueChange = viewModel::setNpubInput,
                label = { Text("npub1... or user@domain.com") },
                isError = error != null,
                supportingText = error?.let { { Text(it, color = ErrorRed) } },
                singleLine = true,
                trailingIcon = {
                    IconButton(onClick = {
                        qrLauncher.launch(
                            ScanOptions().apply {
                                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                setPrompt("Scan a Nostr QR code")
                                setBeepEnabled(false)
                                setOrientationLocked(true)
                            }
                        )
                    }) {
                        Icon(
                            Icons.Default.QrCodeScanner,
                            contentDescription = "Scan QR code",
                            tint = WizardAccent,
                        )
                    }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(24.dp))
            WizardPrimaryButton(
                text = if (npubInput.contains("@") || (!npubInput.startsWith("npub") && npubInput.contains(".")))
                    "Resolve & Continue" else "Continue",
                enabled = !isLoading && npubInput.isNotBlank(),
                isLoading = isLoading,
                onClick = viewModel::advanceFromAccount,
            )
        } else {
            // Full mode: Generate / Import / Amber
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                WizardOptionCard(
                    title = "Generate New",
                    subtitle = "Create a new Nostr identity",
                    selected = mode == AccountMode.GENERATE,
                    onClick = { viewModel.setAccountMode(AccountMode.GENERATE) },
                    modifier = Modifier.weight(1f),
                )
                WizardOptionCard(
                    title = "Import Key",
                    subtitle = "Use an existing nsec",
                    selected = mode == AccountMode.IMPORT,
                    onClick = { viewModel.setAccountMode(AccountMode.IMPORT) },
                    modifier = Modifier.weight(1f),
                )
            }

            if (isAmberAvailable) {
                Spacer(Modifier.height(12.dp))
                WizardOptionCard(
                    title = "Use Amber Signer",
                    subtitle = "Sign events with the Amber app (NIP-55)",
                    selected = mode == AccountMode.AMBER,
                    onClick = { viewModel.setAccountMode(AccountMode.AMBER) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(12.dp))
            WizardOptionCard(
                title = "Connect Remote Signer",
                subtitle = "Any NIP-46 signer — nsec.app, a bunker, your own",
                selected = mode == AccountMode.REMOTE_SIGNER,
                onClick = { viewModel.setAccountMode(AccountMode.REMOTE_SIGNER) },
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(24.dp))

            AnimatedVisibility(visible = mode == AccountMode.IMPORT) {
                Column {
                    OutlinedTextField(
                        value = nsecInput,
                        onValueChange = viewModel::setNsecInput,
                        label = { Text("nsec1...") },
                        visualTransformation = PasswordVisualTransformation(),
                        isError = error != null,
                        supportingText = error?.let { { Text(it, color = ErrorRed) } },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                        colors = wizardTextFieldColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            AnimatedVisibility(visible = mode == AccountMode.REMOTE_SIGNER) {
                Column {
                    Text(
                        text = "Paste or scan the bunker:// string your signer gives you. Your key stays with the signer -- Nostr Vault never sees it.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        value = bunkerInput,
                        onValueChange = viewModel::setBunkerInput,
                        label = { Text("bunker://...") },
                        isError = error != null,
                        supportingText = error?.let { { Text(it, color = ErrorRed) } },
                        singleLine = true,
                        trailingIcon = {
                            IconButton(onClick = {
                                bunkerScanner.launch(
                                    ScanOptions().apply {
                                        setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                        setPrompt("Scan your signer's bunker:// code")
                                        setBeepEnabled(false)
                                        setOrientationLocked(true)
                                    }
                                )
                            }) {
                                Icon(
                                    Icons.Default.QrCodeScanner,
                                    contentDescription = "Scan bunker QR code",
                                    tint = WizardAccent,
                                )
                            }
                        },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                        colors = wizardTextFieldColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            AnimatedVisibility(visible = mode == AccountMode.AMBER) {
                Column {
                    Text(
                        text = "Amber will handle all event signing. Your private key stays in Amber -- Nostr Vault never sees it.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            error?.let { errorText ->
                if (mode != AccountMode.IMPORT) {
                    Text(errorText, color = ErrorRed, fontSize = 13.sp)
                    Spacer(Modifier.height(8.dp))
                }
            }

            WizardPrimaryButton(
                text = when (mode) {
                    AccountMode.GENERATE -> "Generate Keypair"
                    AccountMode.IMPORT -> "Import Key"
                    AccountMode.AMBER -> "Connect Amber"
                    AccountMode.REMOTE_SIGNER -> "Connect Signer"
                },
                enabled = !isLoading && when (mode) {
                    AccountMode.IMPORT -> nsecInput.isNotBlank()
                    AccountMode.REMOTE_SIGNER -> bunkerInput.trim().startsWith("bunker://")
                    else -> true
                },
                isLoading = isLoading,
                onClick = viewModel::advanceFromAccount,
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 4: Relay Configuration (editable)
// ══════════════════════════════════════════════════════════════════

@Composable
private fun RelayStep(viewModel: SetupWizardViewModel) {
    val relays by viewModel.wizardRelays.collectAsState()
    val newRelayInput by viewModel.newRelayInput.collectAsState()
    val macRelayInput by viewModel.macRelayInput.collectAsState()
    val focusManager = LocalFocusManager.current

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Relay Configuration",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "These relays will be used for your feed. Your personal relay also runs on-device.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Haven relay section
        WizardCard {
            Column(modifier = Modifier.padding(4.dp)) {
                Text(
                    text = "Sync with Haven Relay",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "If you already run a Haven relay, enter its URL to stay synced.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = macRelayInput,
                    onValueChange = viewModel::setMacRelayInput,
                    placeholder = { Text("wss://relay.yourdomain.com", color = TertiaryText) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                    colors = wizardTextFieldColors(),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "This can be a Mac, Linux, or cloud-hosted Haven relay. Leave blank to skip.",
                    color = TertiaryText,
                    fontSize = 11.sp,
                )
            }
        }

        Spacer(Modifier.height(20.dp))

        // Add relay input
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            OutlinedTextField(
                value = newRelayInput,
                onValueChange = viewModel::setNewRelayInput,
                placeholder = { Text("wss://relay.example.com", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = {
                    viewModel.addWizardRelay()
                    focusManager.clearFocus()
                }),
                colors = wizardTextFieldColors(),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = viewModel::addWizardRelay,
                enabled = newRelayInput.isNotBlank(),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Create,
                    contentDescription = "Add",
                    tint = if (newRelayInput.isNotBlank()) WizardAccent else TertiaryText,
                )
            }
        }

        Spacer(Modifier.height(12.dp))

        // Relay list
        WizardCard {
            if (relays.isEmpty()) {
                Text(
                    text = "No relays configured",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                )
            } else {
                for ((index, relay) in relays.withIndex()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Domain,
                            contentDescription = null,
                            tint = WizardAccent,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = relay.removePrefix("wss://"),
                            color = PrimaryText,
                            fontSize = 14.sp,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(
                            onClick = { viewModel.removeWizardRelay(relay) },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Dismiss,
                                contentDescription = "Remove",
                                tint = ErrorRed,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                    if (index < relays.lastIndex) {
                        HorizontalDivider(
                            color = WizardBorderSubtle,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 28.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromRelays)
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 5: Import Notes
// ══════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ImportNotesStep(viewModel: SetupWizardViewModel) {
    val isImporting by viewModel.isImporting.collectAsState()
    val importStatus by viewModel.importStatus.collectAsState()
    val importCompleted by viewModel.importCompleted.collectAsState()
    val importStartDate by viewModel.importStartDate.collectAsState()
    val context = LocalContext.current

    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Network", "Backup")
    var showDatePicker by remember { mutableStateOf(false) }

    // File picker for backup restore
    val backupPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            // Copy to temp file for JNI access
            val tempFile = File(context.cacheDir, "restore_backup.zip")
            context.contentResolver.openInputStream(it)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.restoreFromBackup(tempFile.absolutePath)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Import Notes",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Bring your existing notes into your personal relay.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Tab selector
        WizardTabRow(tabs = tabs, selectedTab = selectedTab, onTabSelected = { selectedTab = it })

        Spacer(Modifier.height(16.dp))

        AnimatedContent(
            targetState = selectedTab,
            label = "import_tab",
        ) { tab ->
            when (tab) {
                0 -> {
                    // Network import
                    WizardCard {
                        Text(
                            text = "Import from Network",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Fetch your notes from public relays and store them locally.",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (importStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = importStatus,
                                color = if (importCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isImporting) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        if (!isImporting && !importCompleted) {
                            Spacer(Modifier.height(12.dp))
                            HorizontalDivider(color = WizardBorderSubtle)
                            Spacer(Modifier.height(12.dp))

                            // Date picker row
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable { showDatePicker = true }
                                    .padding(vertical = 8.dp),
                            ) {
                                Text(
                                    text = "Import from",
                                    color = SecondaryText,
                                    fontSize = 14.sp,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(
                                    text = importStartDate,
                                    color = WizardAccent,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Medium,
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isImporting && !importCompleted) {
                            WizardPrimaryButton(
                                text = "Import Notes",
                                onClick = viewModel::startNetworkImport,
                            )
                        } else if (isImporting) {
                            WizardSecondaryButton(
                                text = "Cancel",
                                onClick = viewModel::cancelImport,
                            )
                        }
                    }
                }
                1 -> {
                    // Backup restore
                    WizardCard {
                        Text(
                            text = "Restore from Backup",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Restore from a previous Nostr Vault backup file (.zip).",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (importStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = importStatus,
                                color = if (importCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isImporting) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isImporting && !importCompleted) {
                            WizardPrimaryButton(
                                text = "Choose Backup File",
                                onClick = {
                                    backupPicker.launch(arrayOf(
                                        "application/zip",
                                        "application/x-zip-compressed",
                                    ))
                                },
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        if (importCompleted) {
            WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromImport)
        } else if (!isImporting) {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipImport)
        }
    }

    // Date picker dialog
    if (showDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = try {
                java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).let { fmt ->
                    fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
                    fmt.parse(importStartDate)?.time ?: 0L
                }
            } catch (_: Exception) { 0L }
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                        fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
                        viewModel.setImportStartDate(fmt.format(java.util.Date(millis)))
                    }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text("Cancel") }
            },
        ) {
            DatePicker(state = datePickerState)
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 6: Mirror Media (Blossom)
// ══════════════════════════════════════════════════════════════════

@Composable
private fun MirrorMediaStep(viewModel: SetupWizardViewModel) {
    val blossomURL by viewModel.blossomURL.collectAsState()
    val isMirroring by viewModel.isMirroring.collectAsState()
    val mirrorProgress by viewModel.mirrorProgress.collectAsState()
    val mirrorStatus by viewModel.mirrorStatus.collectAsState()
    val mirrorCompleted by viewModel.mirrorCompleted.collectAsState()
    val context = LocalContext.current

    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Server Sync", "Backup")

    // File picker for media archive
    val mediaPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            val tempFile = File(context.cacheDir, "media_import.zip")
            context.contentResolver.openInputStream(it)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.importMediaArchive(tempFile.absolutePath)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Mirror Media",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Sync your media from an external Blossom server to your device.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        WizardTabRow(tabs = tabs, selectedTab = selectedTab, onTabSelected = { selectedTab = it })

        Spacer(Modifier.height(16.dp))

        AnimatedContent(
            targetState = selectedTab,
            label = "media_tab",
        ) { tab ->
            when (tab) {
                0 -> {
                    // Server sync
                    WizardCard {
                        Text(
                            text = "Sync from Blossom Server",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = blossomURL,
                            onValueChange = viewModel::setBlossomURL,
                            label = { Text("Blossom server URL") },
                            singleLine = true,
                            colors = wizardTextFieldColors(),
                            modifier = Modifier.fillMaxWidth(),
                        )

                        if (mirrorStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = mirrorStatus,
                                color = if (mirrorCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isMirroring) {
                            Spacer(Modifier.height(12.dp))
                            if (mirrorProgress >= 0f) {
                                LinearProgressIndicator(
                                    progress = { mirrorProgress },
                                    color = WizardAccent,
                                    trackColor = WizardBgElevated,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            } else {
                                LinearProgressIndicator(
                                    color = WizardAccent,
                                    trackColor = WizardBgElevated,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isMirroring && !mirrorCompleted) {
                            WizardPrimaryButton(
                                text = "Start Sync",
                                enabled = blossomURL.isNotBlank(),
                                onClick = viewModel::startMediaMirror,
                            )
                        }
                    }
                }
                1 -> {
                    // Backup import
                    WizardCard {
                        Text(
                            text = "Import Media Archive",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Import a media archive (.zip) from a previous backup.",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (mirrorStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = mirrorStatus,
                                color = if (mirrorCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isMirroring) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isMirroring && !mirrorCompleted) {
                            WizardPrimaryButton(
                                text = "Choose Archive",
                                onClick = {
                                    mediaPicker.launch(arrayOf(
                                        "application/zip",
                                        "application/x-zip-compressed",
                                    ))
                                },
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        if (mirrorCompleted) {
            WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromMedia)
        } else if (!isMirroring) {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipMedia)
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 7: Wallet Setup
// ══════════════════════════════════════════════════════════════════

@Composable
private fun WalletSetupStep(viewModel: SetupWizardViewModel) {
    val nwcInput by viewModel.nwcInput.collectAsState()
    val focusManager = LocalFocusManager.current

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Wallet Setup",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Connect a Lightning wallet to send and receive zaps. Optional.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // NWC section
        WizardCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    tint = WizardAccent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Lightning (NWC)",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = nwcInput,
                onValueChange = viewModel::setNwcInput,
                placeholder = { Text("nostr+walletconnect://...", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(Modifier.height(16.dp))

        Spacer(Modifier.height(32.dp))

        if (nwcInput.isNotBlank()) {
            WizardPrimaryButton(text = "Save & Continue", onClick = viewModel::advanceFromWallet)
        } else {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipWallet)
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step 8: Complete
// ══════════════════════════════════════════════════════════════════

@Composable
private fun CompleteStep(
    setupPath: SetupPath,
    onFinish: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        WizardCard {
            Text(
                text = when (setupPath) {
                    SetupPath.NEW_TO_NOSTR -> "Welcome to Nostr!"
                    else -> "You're all set!"
                },
                color = WizardAccent,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(16.dp))

            when (setupPath) {
                SetupPath.NEW_TO_NOSTR -> {
                    WizardCheckItem("Account created")
                    WizardCheckItem("Relay is running")
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "We'll start you on the Popular feed so you can discover " +
                            "interesting people to follow. You can switch to the " +
                            "Following feed anytime.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                SetupPath.BROWSE -> {
                    WizardCheckItem("Connected to Nostr")
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "You're in browse mode. Upgrade to full setup for signing, your own relay, and media storage.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                else -> {
                    WizardCheckItem("Relay is running")
                    WizardCheckItem("DMs enabled")
                    WizardCheckItem("Blossom media active")
                    WizardCheckItem("Posts being broadcast")
                }
            }
        }

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(
            text = when (setupPath) {
                SetupPath.NEW_TO_NOSTR -> "Start Exploring"
                else -> "Open Nostr Vault"
            },
            onClick = onFinish,
        )
    }
}

@Composable
private fun WizardCheckItem(text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Check,
            contentDescription = null,
            tint = SuccessGreen,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(text, color = PrimaryText, fontSize = 15.sp)
    }
}

// ══════════════════════════════════════════════════════════════════
// Reusable wizard components
// ══════════════════════════════════════════════════════════════════

@Composable
private fun WizardCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(WizardBgCard)
            .border(1.dp, WizardBorderSubtle, RoundedCornerShape(16.dp))
            .padding(24.dp),
        content = content,
    )
}

@Composable
private fun WizardOptionCard(
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) WizardBgElevated else WizardBgCard)
            .border(
                width = if (selected) 2.dp else 1.dp,
                color = if (selected) WizardBorderActive else WizardBorderSubtle,
                shape = RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Text(
            text = title,
            color = if (selected) WizardAccent else PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = subtitle,
            color = SecondaryText,
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun WizardPrimaryButton(
    text: String,
    enabled: Boolean = true,
    isLoading: Boolean = false,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !isLoading,
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent,
        ),
        contentPadding = PaddingValues(),
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .background(
                    brush = if (enabled) WizardGradient
                    else Brush.horizontalGradient(
                        listOf(Color(0xFF52525B), Color(0xFF52525B)),
                    ),
                    shape = RoundedCornerShape(12.dp),
                ),
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(22.dp),
                )
            } else {
                Text(
                    text = text,
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun WizardSecondaryButton(
    text: String,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 15.sp,
        )
    }
}

@Composable
private fun WizardTabRow(
    tabs: List<String>,
    selectedTab: Int,
    onTabSelected: (Int) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        for ((index, tab) in tabs.withIndex()) {
            val isSelected = index == selectedTab
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (isSelected) WizardBgElevated else Color.Transparent)
                    .border(
                        width = 1.dp,
                        color = if (isSelected) WizardBorderActive else WizardBorderSubtle,
                        shape = RoundedCornerShape(8.dp),
                    )
                    .clickable { onTabSelected(index) }
                    .padding(vertical = 10.dp),
            ) {
                Text(
                    text = tab,
                    color = if (isSelected) WizardAccent else SecondaryText,
                    fontSize = 14.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step: Initial Follows
// ══════════════════════════════════════════════════════════════════

@Composable
private fun InitialFollowsStep(viewModel: SetupWizardViewModel) {
    val starterPacks by viewModel.starterPacks.collectAsState()
    val selectedNpubs by viewModel.selectedNpubs.collectAsState()
    val expandedPackId by viewModel.expandedPackId.collectAsState()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        // Header
        Text(
            text = "Discover Accounts",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Following accounts helps personalize your feed. Select any that interest you, or skip to explore on your own.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 22.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Packs list
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState()),
        ) {
            starterPacks?.packs?.forEach { pack ->
                PackCard(
                    pack = pack,
                    isExpanded = expandedPackId == pack.id,
                    selectedNpubs = selectedNpubs,
                    onToggleExpand = { viewModel.togglePackExpansion(pack.id) },
                    onToggleAccount = { viewModel.toggleAccountSelection(it) },
                )
                Spacer(Modifier.height(12.dp))
            } ?: run {
                Text("Loading packs...", color = SecondaryText)
            }
        }

        Spacer(Modifier.height(16.dp))

        // Selected count badge
        AnimatedVisibility(visible = selectedNpubs.isNotEmpty()) {
            Row(
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(WizardBgCard)
                    .border(1.dp, WizardAccent, RoundedCornerShape(20.dp))
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = null,
                    tint = WizardAccent,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "${selectedNpubs.size} account${if (selectedNpubs.size == 1) "" else "s"} selected",
                    color = PrimaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        // Buttons
        WizardPrimaryButton(
            text = if (selectedNpubs.isEmpty()) "Skip for Now" else "Follow ${selectedNpubs.size}",
            onClick = {
                if (selectedNpubs.isEmpty()) {
                    viewModel.skipInitialFollows()
                } else {
                    viewModel.advanceFromInitialFollows()
                }
            },
        )

        if (selectedNpubs.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = viewModel::skipInitialFollows) {
                Text("Skip and don't follow", color = SecondaryText, fontSize = 14.sp)
            }
        }
    }
}

@Composable
private fun PackCard(
    pack: com.nostrvault.data.model.StarterPack,
    isExpanded: Boolean,
    selectedNpubs: Set<String>,
    onToggleExpand: () -> Unit,
    onToggleAccount: (String) -> Unit,
) {
    WizardCard {
        // Pack header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggleExpand),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = pack.name,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = pack.description,
                    color = SecondaryText,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    imageVector = if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (isExpanded) "Collapse" else "Expand",
                    tint = WizardAccent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "${pack.accounts.size}",
                    color = SecondaryText,
                    fontSize = 11.sp,
                )
            }
        }

        // Expanded accounts list
        AnimatedVisibility(visible = isExpanded) {
            Column(modifier = Modifier.padding(top = 12.dp)) {
                pack.accounts.forEach { account ->
                    AccountRow(
                        account = account,
                        isSelected = selectedNpubs.contains(account.npub),
                        onToggle = { onToggleAccount(account.npub) },
                    )
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun AccountRow(
    account: com.nostrvault.data.model.RecommendedAccount,
    isSelected: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(if (isSelected) WizardBgCard else WizardBgElevated)
            .border(
                width = if (isSelected) 1.dp else 0.dp,
                color = if (isSelected) WizardAccent else Color.Transparent,
                shape = RoundedCornerShape(8.dp),
            )
            .clickable(onClick = onToggle)
            .padding(10.dp),
    ) {
        // Checkbox
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(24.dp),
        ) {
            if (isSelected) {
                Box(
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                        .background(
                            Brush.horizontalGradient(
                                colors = listOf(
                                    Color(0xFF6366F1),
                                    Color(0xFF8B5CF6),
                                )
                            )
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Default.Check,
                        contentDescription = "Selected",
                        tint = Color.White,
                        modifier = Modifier.size(14.dp),
                    )
                }
            } else {
                Box(
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                        .border(2.dp, WizardBorderSubtle, CircleShape)
                        .background(WizardBgElevated),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        // Account info
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = account.name,
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = account.about,
                color = SecondaryText,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun wizardTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = WizardAccent,
    unfocusedBorderColor = WizardBorderSubtle,
    cursorColor = WizardAccent,
    focusedLabelColor = WizardAccent,
)
