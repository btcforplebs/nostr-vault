package com.nostrvault.ui.screens

import android.content.Context
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
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
import com.nostrvault.service.RelayImportService
import com.nostrvault.service.StatsService
import com.nostrvault.setup.IdentityInput
import com.nostrvault.setup.RelayCheck
import com.nostrvault.setup.RelayCheckProbe
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.URL
import javax.inject.Inject

// ── Enums ────────────────────────────────────────────────────────

/** Where "I already use Nostr"'s import starts. Same as iOS. */
internal const val IMPORT_TOUR_START_DATE = "2023-01-01"

enum class WizardStep {
    WELCOME, RELAY_CHOICE, NOSTR_INTRO, KEY_PASSWORD, PROFILE, USE_NOSTR_KEY, RELAY_CHECK, IMPORT_TOUR,
    ACCOUNT, RELAYS, IMPORT_NOTES, MIRROR_MEDIA, WALLET, NOTIFICATIONS, COMPLETE
}

enum class AccountMode { GENERATE, IMPORT, AMBER, REMOTE_SIGNER }
/** [USE_NOSTR] is "I already use Nostr": one key field decides read-only vs
 *  can-post, so it replaces [FULL] and [BROWSE] on the front door. Same as iOS. */
enum class SetupPath { NONE, FULL, BROWSE, NEW_TO_NOSTR, USE_NOSTR }

// ── ViewModel ────────────────────────────────────────────────────

@HiltViewModel
class SetupWizardViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val credentialStore: CredentialStore,
    private val amberSignerService: AmberSignerService,
    private val blossomService: BlossomService,
    private val nostrService: NostrService,
    private val relayImportService: RelayImportService,
    private val statsService: StatsService,
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


    // New account: published once setup completes (see publishNewAccount)
    private val _profileName = MutableStateFlow("")
    val profileName = _profileName.asStateFlow()

    private val _profilePhotoJpeg = MutableStateFlow<ByteArray?>(null)
    val profilePhotoJpeg = _profilePhotoJpeg.asStateFlow()

    private val _profilePhotoError = MutableStateFlow<String?>(null)
    val profilePhotoError = _profilePhotoError.asStateFlow()

    /** The new account's npub, shown on the keys page beside the nsec. */
    private val _generatedNpub = MutableStateFlow<String?>(null)
    val generatedNpub = _generatedNpub.asStateFlow()
    /** The pubkey New to Nostr generated this run. Only this key may be
     *  marked fresh or have a profile published for it at the end. */
    private var generatedPkHex: String? = null

    /** Keys this run of setup stored that weren't on the device before, so a
     *  key left behind by Back and another choice can be removed again. */
    private val wizardStoredKeys = mutableSetOf<String>()

    // I already use Nostr
    private val _useNostrInput = MutableStateFlow("")
    val useNostrInput = _useNostrInput.asStateFlow()

    private val _useNostrPassword = MutableStateFlow("")
    val useNostrPassword = _useNostrPassword.asStateFlow()

    private val _useNostrConfirm = MutableStateFlow("")
    val useNostrConfirm = _useNostrConfirm.asStateFlow()

    private val _relayRows = MutableStateFlow<List<RelayCheck.Row>>(emptyList())
    val relayRows = _relayRows.asStateFlow()

    private val _isCheckingRelays = MutableStateFlow(true)
    val isCheckingRelays = _isCheckingRelays.asStateFlow()
    /** The account the rows were checked for; another key checks again. */
    private var relayCheckPubkey: String? = null

    /** The import tour runs the app-wide import, so it outlives this screen. */
    val tourIsImporting = relayImportService.isImporting
    val tourImportCompleted = relayImportService.importCompleted
    val tourImportProgress = relayImportService.importProgress
    val tourImportStatus = relayImportService.importStatusMessage

    /** Notes, likes and everything, read from the relay once the import is done. */
    private val _tourCounts = MutableStateFlow<Triple<Int, Int, Int>?>(null)
    val tourCounts = _tourCounts.asStateFlow()
    /** The account whose import the tour started. */
    private var importTourPubkey: String? = null

    /** The tour's import ran and stopped without finishing. Kept here, not in
     *  the screen, so leaving and returning to the step still knows. */
    private val _tourImportFailed = MutableStateFlow(false)
    val tourImportFailed = _tourImportFailed.asStateFlow()

    init {
        _isAmberAvailable.value = amberSignerService.isAmberInstalled()
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
        WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.ACCOUNT,
        WizardStep.RELAYS, WizardStep.IMPORT_NOTES, WizardStep.MIRROR_MEDIA,
        WizardStep.WALLET, WizardStep.NOTIFICATIONS, WizardStep.COMPLETE,
    )

    /** Steps for browse mode. */
    private val browseSteps = listOf(
        WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.ACCOUNT,
        WizardStep.IMPORT_NOTES, WizardStep.COMPLETE,
    )

    /** Steps for "New to Nostr" mode: keys, password, profile, done. The
     *  Fill your feed guide finds people after setup. */
    private val newUserSteps = listOf(
        WizardStep.WELCOME, WizardStep.RELAY_CHOICE,
        WizardStep.NOSTR_INTRO, WizardStep.KEY_PASSWORD, WizardStep.PROFILE, WizardStep.COMPLETE,
    )

    /** Steps for "I already use Nostr": your key, relay check, import tour.
     *  The tour's Enter finishes setup, so there's no done screen. */
    private val useNostrSteps = listOf(
        WizardStep.WELCOME, WizardStep.RELAY_CHOICE,
        WizardStep.USE_NOSTR_KEY, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR,
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
                SetupPath.USE_NOSTR -> useNostrSteps
                else -> fullSteps
            }
            return if (_useExternalRelay.value) {
                // No import here, so "I already use Nostr" ends on the done screen.
                val withoutImport = steps - WizardStep.IMPORT_NOTES - WizardStep.MIRROR_MEDIA -
                    WizardStep.RELAY_CHECK - WizardStep.IMPORT_TOUR
                if (WizardStep.COMPLETE in withoutImport) withoutImport else withoutImport + WizardStep.COMPLETE
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

    /** The front door's three buttons. Every path goes on to the relay choice. */
    fun choosePath(path: SetupPath) {
        // Every way in starts with no identity. A key made or pasted on an
        // earlier visit must not be shown again, or signed with, on this one.
        forgetWizardKeys(except = null)
        _generatedNsec.value = null
        _generatedSkHex.value = null
        _generatedNpub.value = null
        generatedPkHex = null
        _passphrase.value = ""
        _confirmPassphrase.value = ""
        _useNostrInput.value = ""
        _useNostrPassword.value = ""
        _useNostrConfirm.value = ""
        _error.value = null
        _setupPath.value = path
        _step.value = WizardStep.RELAY_CHOICE
    }

    /** Records that setup stored [pkHex]'s key, unless it was already here. */
    private fun storeWizardKey(skHex: String, pkHex: String) {
        if (credentialStore.getNsec(pkHex) == null) wizardStoredKeys.add(pkHex)
        credentialStore.saveNsec(skHex, pkHex)
    }

    /**
     * Removes keys this run of setup stored, other than [except]: their nsec,
     * their keychain password, and the owner fields when one of them is the
     * owner. Keys that were on the device before setup are never touched.
     */
    private fun forgetWizardKeys(except: String?) {
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
    private fun ownerIsGeneratedKey(): Boolean {
        val generated = generatedPkHex ?: return false
        return HavenBridge.decodeNpub(configStore.config.value.ownerNpub) == generated
    }

    fun advanceFromRelayChoice() {
        val external = _useExternalRelay.value
        val relayURL = _externalRelayInput.value.trim()
        val blossomURL = _externalBlossomInput.value.trim()
        if (external) {
            if (normalizeExternalRelayURL(relayURL) == null) {
                _error.value = "Enter a relay app on this phone (ws://127.0.0.1:4869) or your relay's wss:// address"
                return
            }
            if (blossomURL.isNotEmpty() && normalizeExternalBlossomURL(blossomURL) == null) {
                _error.value = "Enter a Blossom address on this phone (http://127.0.0.1:port) or an https:// address"
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
        storeWizardKey(skHex, pkHex)
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
    fun advanceFromNostrIntro() {
        _error.value = null
        _step.value = stepAfter(WizardStep.NOSTR_INTRO)
    }

    /** Password page: encrypts the new key with it (NIP-49), then the profile. */
    fun advanceFromKeyPassword() {
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

    fun setProfileName(value: String) { _profileName.value = value }

    /** Reads the picked image into a JPEG of at most 512 px; same as iOS. */
    fun setProfilePhoto(uri: android.net.Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            val jpeg = runCatching { profileJpeg(uri) }.getOrNull()
            withContext(Dispatchers.Main) {
                if (jpeg != null) {
                    _profilePhotoJpeg.value = jpeg
                    _profilePhotoError.value = null
                } else {
                    _profilePhotoError.value = "Couldn't read that photo. Try another."
                }
            }
        }
    }

    /**
     * Decodes [uri] downsampled to at most [maxPixel] on its longest side and
     * re-encodes it as JPEG. A fresh encode carries no EXIF, so the original's
     * location never leaves the phone.
     */
    private fun profileJpeg(uri: android.net.Uri, maxPixel: Int = 512): ByteArray? {
        val resolver = appContext.contentResolver
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it, null, bounds) }
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return null
        var sample = 1
        while (longest / (sample * 2) >= maxPixel) sample *= 2
        val decoded = resolver.openInputStream(uri)?.use {
            android.graphics.BitmapFactory.decodeStream(it, null, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val rotation = resolver.openInputStream(uri)?.use {
            when (androidx.exifinterface.media.ExifInterface(it).getAttributeInt(
                androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION,
                androidx.exifinterface.media.ExifInterface.ORIENTATION_NORMAL,
            )) {
                androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } ?: 0f
        val scale = minOf(1f, maxPixel.toFloat() / maxOf(decoded.width, decoded.height))
        val matrix = android.graphics.Matrix().apply {
            postScale(scale, scale)
            postRotate(rotation)
        }
        val bitmap = android.graphics.Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        val out = java.io.ByteArrayOutputStream()
        if (!bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)) return null
        return out.toByteArray()
    }

    fun advanceFromProfile() { _step.value = stepAfter(WizardStep.PROFILE) }

    fun skipProfile() {
        _profileName.value = ""
        _profilePhotoJpeg.value = null
        _step.value = stepAfter(WizardStep.PROFILE)
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
    private suspend fun connectRemoteSignerOwner(uri: String, clientSec: String, clientPub: String): Boolean {
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
    suspend fun pairNostrConnect(request: NIP46Service.NostrConnectRequest, signerPubkey: String): String? =
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

    // ── I already use Nostr ───────────────────────────────────────

    fun setUseNostrInput(value: String) {
        _useNostrInput.value = value
        _useNostrPassword.value = ""
        _useNostrConfirm.value = ""
        _error.value = null
    }
    fun setUseNostrPassword(value: String) { _useNostrPassword.value = value; _error.value = null }
    fun setUseNostrConfirm(value: String) { _useNostrConfirm.value = value; _error.value = null }

    /**
     * A pasted nsec gets a new password, so the same rules as New to Nostr's
     * password page: 8 characters and typed twice. An ncryptsec's password
     * already exists and only has to unlock it.
     */
    fun useNostrPasswordProblem(input: IdentityInput): String? {
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
    fun keyChecksumOK(input: IdentityInput): Boolean = when (input) {
        is IdentityInput.PublicKey -> HavenBridge.decodeNpub(input.key) != null
        is IdentityInput.SecretKey -> HavenBridge.nsecToHex(input.key) != null
        else -> true
    }

    /**
     * The key step's Continue. What was pasted decides the account: a public
     * key or name@domain is read-only, a private key, encrypted key or
     * bunker:// link can post. Same as iOS `UseNostrKeyStep.handleContinue`.
     */
    fun continueUseNostr() {
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
    fun useAmberForUseNostr() {
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
    private fun adoptReadOnly(npub: String): Boolean {
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
    private suspend fun adoptSecretKey(skHex: String, password: String, ncryptsec: String?): Boolean {
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
    fun setupModeNow(): String = configStore.config.value.setupMode

    // ── Relay check ───────────────────────────────────────────────

    /**
     * Their relay list says where their notes are; the defaults are where
     * most people's notes also land. Each is asked for one note at once, and
     * the ones that don't answer are switched off. Runs once per visit.
     */
    fun startRelayCheck(force: Boolean = false) {
        val pubkey = HavenBridge.decodeNpub(configStore.config.value.ownerNpub) ?: run {
            _relayRows.value = emptyList()
            _isCheckingRelays.value = false
            _error.value = "Couldn't read your key. Go back and paste it again."
            return
        }
        if (!force && pubkey == relayCheckPubkey) return
        relayCheckPubkey = pubkey
        _error.value = null
        viewModelScope.launch {
            _isCheckingRelays.value = true
            val list = runCatching {
                nostrService.fetchNewestReplaceable(10002, pubkey, alsoAsk = configStore.config.value.importSeedRelays)
            }.getOrNull()
            _relayRows.value = RelayCheck.rows(list?.tags ?: emptyList(), HavenConfig().importSeedRelays)
            _relayRows.value.map { row ->
                launch { probeRelayRow(row.url, pubkey) }
            }.joinAll()
            _isCheckingRelays.value = false
        }
    }

    private suspend fun probeRelayRow(url: String, pubkey: String) {
        val result = RelayCheckProbe.check(url, pubkey)
        _relayRows.update { rows ->
            rows.map { if (it.url == url) it.copy(result = result, isOn = result.onByDefault) else it }
        }
    }

    fun setRelayRowOn(url: String, on: Boolean) {
        _relayRows.update { rows -> rows.map { if (it.url == url && it.result.canImport) it.copy(isOn = on) else it } }
    }

    /** Adds a relay to the check and probes it. False when it isn't a relay address. */
    fun addRelayCheckRow(raw: String): Boolean {
        val url = RelayCheck.normalize(raw) ?: return false
        if (_relayRows.value.any { it.url == url }) return true
        val pubkey = HavenBridge.decodeNpub(configStore.config.value.ownerNpub) ?: return false
        _relayRows.update { it + RelayCheck.Row(url, isYours = false) }
        viewModelScope.launch { probeRelayRow(url, pubkey) }
        return true
    }

    /** "Start import": the picks become what the import reads. */
    fun startImportFromRelayCheck() {
        val picks = RelayCheck.importList(_relayRows.value)
        if (picks.isEmpty()) return
        configStore.update { it.copy(importSeedRelays = picks) }
        _step.value = stepAfter(WizardStep.RELAY_CHECK)
    }

    // ── Import tour ───────────────────────────────────────────────

    /**
     * Starts the import as soon as the tour shows. It runs in
     * [RelayImportService], not here, so "Keep it running in the background"
     * can leave setup with it still going.
     */
    fun startImportTour() {
        val pubkey = HavenBridge.decodeNpub(configStore.config.value.ownerNpub).orEmpty()
        if (pubkey == importTourPubkey) return
        val sameAccountAgain = importTourPubkey == null
        importTourPubkey = pubkey
        _tourImportFailed.value = false
        _tourCounts.value = null
        if (sameAccountAgain && relayImportService.importCompleted.value && !relayImportService.isImporting.value) {
            loadTourCounts()
            return
        }
        if (relayImportService.isImporting.value) return
        // Same start as iOS. 2021 was tried there: the import walks history in
        // 10-day windows, each waiting on every relay, so two more years cost
        // minutes for everyone. Older notes can be pulled from Settings → Import.
        configStore.update { it.copy(importStartDate = IMPORT_TOUR_START_DATE) }
        relayImportService.importNotes()
        viewModelScope.launch {
            relayImportService.isImporting.first { it }
            relayImportService.isImporting.first { !it }
            if (!relayImportService.importCompleted.value) _tourImportFailed.value = true
        }
    }

    /** Real counts for the Ready card, once the relay is back up. */
    fun loadTourCounts() {
        if (_tourCounts.value != null) return
        viewModelScope.launch {
            // The import restarts the relay when it finishes; give it a moment.
            for (attempt in 1..10) {
                statsService.fetchCountsByKind()
                if (statsService.loadedEventsCount.value > 0) break
                kotlinx.coroutines.delay(1_500)
            }
            val counts = statsService.kindCounts.value
            _tourCounts.value = Triple(counts[1] ?: 0, counts[7] ?: 0, statsService.loadedEventsCount.value)
        }
    }

    /**
     * Leaves the tour and finishes setup. Seeing every lesson card finishes
     * the tutorial (and covers Vault and Pocket relay); leaving before the
     * last one counts as skipped. The import carries on if it's still going.
     */
    fun enterFromImportTour(sawEveryCard: Boolean, onComplete: () -> Unit) {
        val account = HavenBridge.decodeNpub(configStore.config.value.ownerNpub).orEmpty()
        if (sawEveryCard) {
            TutorialCenter.finish(TutorialID.IMPORT_TOUR, account)
        } else {
            TutorialCenter.skip(TutorialID.IMPORT_TOUR, account)
        }
        completeSetup(onComplete)
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
        _step.value = stepAfter(WizardStep.WALLET)
    }

    fun skipWallet() { _step.value = stepAfter(WizardStep.WALLET) }

    // ── Notifications ("Stay in the Loop", iOS PushNotificationStep) ──

    /** [enable] is "Enable Notifications" (the caller has asked Android for
     *  the permission); false is "Not now". Either way setup won't ask again. */
    fun finishNotifications(enable: Boolean, dms: Boolean, zaps: Boolean, mentions: Boolean) {
        configStore.update {
            if (enable) {
                it.copy(
                    notificationPermissionAsked = true,
                    pushNotifyDMs = dms,
                    pushNotifyZaps = zaps,
                    pushNotifyMentions = mentions,
                )
            } else {
                it.copy(notificationPermissionAsked = true)
            }
        }
        _step.value = stepAfter(WizardStep.NOTIFICATIONS)
    }

    // ── Complete ─────────────────────────────────────────────────

    fun completeSetup(onComplete: () -> Unit) {
        viewModelScope.launch {
            // Resolve active account hex pubkey (matches iOS refreshActiveAccountHex).
            // Done before hasCompletedSetup flips: MainActivity starts the DM
            // listeners on that flip, and they subscribe for the active account.
            val npub = configStore.config.value.ownerNpub
            if (npub.startsWith("npub1")) {
                try {
                    val hex = HavenBridge.decodeNpub(npub)
                    if (!hex.isNullOrEmpty()) {
                        configStore.setActiveAccount(hex)
                        // A key made here has no follow list anywhere yet. Only
                        // that key: never an account someone pasted in.
                        if (_setupPath.value == SetupPath.NEW_TO_NOSTR && hex == generatedPkHex) {
                            com.nostrvault.service.FreshAccountKeys.mark(appContext, hex)
                            // Straight into Fill your feed: this key follows
                            // nobody yet, so there is nothing to wait for.
                            com.nostrvault.tutorials.TutorialCenter.startIfEligible(
                                com.nostrvault.tutorials.TutorialID.FILL_YOUR_VAULT, hex,
                            )
                        }
                    }
                } catch (_: Exception) {}
            }

            // New accounts start with notifications on (DMs, replies, mentions
            // and zaps per PushPrefs' defaults) — otherwise a
            // first DM arrives silently. Set here rather than as the config
            // default so existing installs keep whatever they had.
            configStore.update { it.copy(hasCompletedSetup = true, enablePushNotifications = true) }

            // Advertise where to send us DMs. Setup never did this, so a new
            // account had no kind 10050 at all and was effectively unreachable
            // over NIP-17 — senders fell through to a guessed relay set and
            // replies had nowhere defined to go.
            runCatching { nostrService.republishDMRelayList() }

            if (_setupPath.value == SetupPath.NEW_TO_NOSTR && ownerIsGeneratedKey()) publishNewAccount()

            onComplete()
        }
    }

    /**
     * Publishes what a brand-new account needs to exist for other people:
     * a relay list and a profile. Its follow list starts with its first
     * follow, in the Fill your feed guide. Same as iOS. Runs once setup has
     * stored the key, because each event is signed by it, and only on New to
     * Nostr, whose key was generated in this run and so has none of these
     * events anywhere yet. Outlives the wizard (app scope).
     */
    private fun publishNewAccount() {
        val name = _profileName.value.trim()
        val photo = _profilePhotoJpeg.value
        val generated = generatedPkHex ?: return
        // Each event is signed by whichever account is active, so check it
        // is still the generated key right before signing.
        fun stillGenerated() = nostrService.activeHexPubkey == generated &&
            HavenBridge.decodeNpub(configStore.config.value.ownerNpub) == generated

        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            if (!stillGenerated()) return@launch
            val relayTags = RelayConfiguration.newAccountRelayListTags(configStore.config.value.activeBlastrRelays)
            if (relayTags.isNotEmpty()) {
                runCatching { nostrService.signEventAsync(kind = 10002, content = "", tags = relayTags) }
                    .getOrNull()?.let { nostrService.postEvent(it) }
            }

            val profile = JSONObject()
            if (name.isNotEmpty()) {
                profile.put("name", name)
                profile.put("display_name", name)
            }
            if (photo != null) {
                // Hosted URL only: a picture only this phone can serve is left off.
                val sha = java.security.MessageDigest.getInstance("SHA-256").digest(photo)
                    .joinToString("") { "%02x".format(it) }
                runCatching { blossomService.uploadAndMirror(photo, sha, "image/jpeg") }
                    .getOrNull()?.let { profile.put("picture", it) }
            }
            if (profile.length() == 0 || !stillGenerated()) return@launch
            runCatching { nostrService.signEventAsync(kind = 0, content = profile.toString(), tags = emptyList()) }
                .getOrNull()?.let { nostrService.postEvent(it) }
        }
    }
}
