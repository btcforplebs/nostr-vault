package com.nostrvault.ui.screens

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CellTower
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Shield
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
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
import com.nostrvault.service.RelayImportService
import com.nostrvault.service.StatsService
import com.nostrvault.setup.IdentityInput
import com.nostrvault.setup.RelayCheck
import com.nostrvault.setup.RelayCheckProbe
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.ui.components.NostrConnectPairing
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

/**
 * Setup wizard for first-run onboarding.
 * Full mode:   Welcome → Path → Account → Relays → Import → Media → Wallet → Complete
 * Browse mode: Welcome → Path → Account → Complete
 * Port of SetupWizardView.swift.
 */

// ── Wizard colors (from iOS WizardColors) ────────────────────────

internal val WizardBgPrimary = Color(0xFF09090B)
internal val WizardBgCard = Color(0xFF18181B)
internal val WizardBgElevated = Color(0xFF27272A)
internal val WizardBorderSubtle = Color.White.copy(alpha = 0.06f)
internal val WizardBorderActive = Color(0xFFF59E0B).copy(alpha = 0.4f)
internal val WizardAccent = Color(0xFFF59E0B)
internal val WizardGradient = Brush.horizontalGradient(
    colors = listOf(Color(0xFFEA580C), Color(0xFFF59E0B)),
)

// ── Enums ────────────────────────────────────────────────────────

/** Where "I already use Nostr"'s import starts. Same as iOS. */
internal const val IMPORT_TOUR_START_DATE = "2023-01-01"

enum class WizardStep {
    WELCOME, RELAY_CHOICE, NOSTR_INTRO, KEY_PASSWORD, PROFILE, USE_NOSTR_KEY, RELAY_CHECK, IMPORT_TOUR,
    ACCOUNT, RELAYS, IMPORT_NOTES, MIRROR_MEDIA, WALLET, COMPLETE
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
        WizardStep.WALLET, WizardStep.COMPLETE,
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
        _step.value = WizardStep.COMPLETE
    }

    fun skipWallet() { _step.value = WizardStep.COMPLETE }

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
        // The front door fills the screen and pins its buttons, so it lives
        // outside the scrolling column, with no Back row, header or dots.
        if (step == WizardStep.WELCOME) {
            FrontDoor(onChoose = viewModel::choosePath)
            return@Box
        }

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

            // Back button
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

            // Step dots. The front door is not step 1 of N, so they count
            // from the screen after it.
            Spacer(Modifier.height(16.dp))
            StepDots(
                totalSteps = viewModel.activeSteps.size - 1,
                currentIndex = viewModel.currentStepIndex - 1,
            )

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
                    // Drawn outside this scrolling column; see FrontDoor above.
                    WizardStep.WELCOME -> Unit
                    WizardStep.RELAY_CHOICE -> RelayChoiceStep(viewModel)
                    WizardStep.NOSTR_INTRO -> NostrIntroStep(viewModel)
                    WizardStep.KEY_PASSWORD -> KeyPasswordStep(viewModel)
                    WizardStep.USE_NOSTR_KEY -> UseNostrKeyStep(viewModel)
                    WizardStep.RELAY_CHECK -> RelayCheckStep(viewModel)
                    WizardStep.IMPORT_TOUR -> ImportTourStep(viewModel, onComplete)
                    WizardStep.PROFILE -> ProfileStep(viewModel)
                    WizardStep.ACCOUNT -> AccountStep(viewModel)
                    WizardStep.RELAYS -> RelayStep(viewModel)
                    WizardStep.IMPORT_NOTES -> ImportNotesStep(viewModel)
                    WizardStep.MIRROR_MEDIA -> MirrorMediaStep(viewModel)
                    WizardStep.WALLET -> WalletSetupStep(viewModel)
                    WizardStep.COMPLETE -> CompleteStep(
                        setupPath = setupPath,
                        readOnly = viewModel.setupModeNow() == "browse",
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
// Step 1: Welcome (the front door)
// ══════════════════════════════════════════════════════════════════

/**
 * The first screen after install. It used to be a card and five feature
 * bullets with Get Started below the fold, then a separate choose-your-setup
 * screen whose Continue only enabled after picking a card. Now it fits one
 * phone screen and the three ways in are the buttons themselves. Same layout
 * numbers as the iOS front door.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FrontDoor(onChoose: (SetupPath) -> Unit) {
    var showWhatsInside by remember { mutableStateOf(false) }
    var appeared by remember { mutableStateOf(Motion.isReduced) }
    LaunchedEffect(Unit) { appeared = true }
    val heroAlpha by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = tween(if (Motion.isReduced) 0 else 450),
        label = "front_door_hero",
    )

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp),
    ) {
        // Tall phones get a bigger icon so the block fills the space instead
        // of floating; small phones are already tight.
        val iconSize = if (maxHeight > 800.dp) 112.dp else 92.dp

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxSize(),
        ) {
            // Centred in the space above the buttons. When it can't fit
            // (large font scale), only this part scrolls and the buttons stay
            // pinned.
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .heightIn(min = maxHeight)
                        .padding(vertical = 16.dp)
                        .alpha(heroAlpha),
                ) {
                    FrontDoorHero(iconSize = iconSize, onWhatsInside = { showWhatsInside = true })
                }
            }

            // No entrance delay: these are tappable on the first frame.
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.padding(top = 16.dp, bottom = 16.dp),
            ) {
                WizardPrimaryButton(text = "Create an account", onClick = { onChoose(SetupPath.NEW_TO_NOSTR) })
                FrontDoorSecondaryButton(text = "I already use Nostr", onClick = { onChoose(SetupPath.USE_NOSTR) })
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .clickable(role = Role.Button) { onChoose(SetupPath.BROWSE) },
                ) {
                    Text(
                        text = "Just look around",
                        color = SecondaryText,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }
    }

    if (showWhatsInside) {
        ModalBottomSheet(
            onDismissRequest = { showWhatsInside = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = WizardBgPrimary,
        ) {
            WhatsInsideSheet(onDone = { showWhatsInside = false })
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FrontDoorHero(iconSize: Dp, onWhatsInside: () -> Unit) {
    // The icon they just tapped on the home screen, with the amber glow.
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(iconSize + 4.dp)) {
        Box(
            modifier = Modifier
                .requiredSize(iconSize * 1.6f)
                .background(
                    Brush.radialGradient(
                        listOf(WizardAccent.copy(alpha = 0.35f), Color.Transparent),
                    ),
                    CircleShape,
                ),
        )
        val corner = RoundedCornerShape(iconSize * 0.2237f)
        Image(
            painter = painterResource(R.drawable.vault_mark),
            contentDescription = null,
            modifier = Modifier
                .size(iconSize)
                .clip(corner)
                .border(1.dp, Color.White.copy(alpha = 0.08f), corner),
        )
    }

    Spacer(Modifier.height(24.dp))
    Text(
        text = "Nostr Vault",
        color = PrimaryText,
        fontSize = 34.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.semantics { heading() },
    )
    Spacer(Modifier.height(8.dp))
    // Broken by hand so it splits at the comma on every width.
    Text(
        text = "Your posts, messages and media,\nkept on your own device.",
        color = SecondaryText,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        textAlign = TextAlign.Center,
    )

    Spacer(Modifier.height(24.dp))
    // Wraps rather than truncating at large font scale. Not buttons: they
    // describe, they don't do anything.
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clearAndSetSemantics { contentDescription = "Includes your own relay, private DMs and zaps" },
    ) {
        FrontDoorChip(NostrVaultIcons.AppIcon, "Own relay")
        FrontDoorChip(NostrVaultIcons.Lock, "Private DMs")
        FrontDoorChip(NostrVaultIcons.Zap, "Zaps")
    }

    Spacer(Modifier.height(12.dp))
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 32.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(role = Role.Button, onClick = onWhatsInside)
            .padding(horizontal = 8.dp),
    ) {
        Text(
            text = "What's inside?",
            color = WizardAccent,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun FrontDoorChip(icon: ImageVector, label: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .heightIn(min = 32.dp)
            .background(WizardBgCard, CircleShape)
            .border(1.dp, BorderStrong, CircleShape)
            .padding(horizontal = 12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(14.dp))
        Text(label, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun FrontDoorSecondaryButton(text: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(shape)
            .background(WizardBgCard, shape)
            .border(1.dp, BorderStrong, shape)
            .clickable(role = Role.Button, onClick = onClick),
    ) {
        Text(text = text, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** The feature descriptions that used to fill the first screen. */
@Composable
private fun WhatsInsideSheet(onDone: () -> Unit) {
    val features = listOf(
        Triple(NostrVaultIcons.AppIcon, "Personal Relay", "Run your own relay on-device. Notes are stored locally and broadcast to the network — you always have a copy."),
        Triple(NostrVaultIcons.Articles, "Full Nostr Client", "Browse your feed, post notes, reply, repost, and discover content from the network."),
        Triple(NostrVaultIcons.Lock, "Private Messaging", "NIP-17 encrypted DMs that stay on your device. No third-party server reads your conversations."),
        Triple(NostrVaultIcons.Media, "Blossom Media", "Host images and videos on your device with Blossom. Mirror media from the network to your local storage."),
        Triple(NostrVaultIcons.Zap, "Lightning Zaps", "Send and receive zaps over Lightning by connecting your own wallet with Nostr Wallet Connect."),
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 20.dp)
            .navigationBarsPadding(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = "What's inside",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
            TextButton(onClick = onDone) {
                Text("Done", color = WizardAccent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Spacer(Modifier.height(12.dp))
        for ((icon, title, line) in features) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 10.dp)
                    .background(WizardBgCard, RoundedCornerShape(12.dp))
                    .border(1.dp, BorderStrong, RoundedCornerShape(12.dp))
                    .padding(14.dp)
                    .semantics(mergeDescendants = true) {},
            ) {
                Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(title, color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(line, color = SecondaryText, fontSize = 14.sp, lineHeight = 20.sp)
                }
            }
        }
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
            title = "A Relay You Already Run",
            subtitle = "A relay app on this phone, e.g. Citrine, or your own relay elsewhere, " +
                "e.g. Nostr Vault for Mac. The built-in relay never starts.",
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
                placeholder = { Text("ws://127.0.0.1:4869 or wss://your.domain") },
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
                placeholder = { Text("https://your.domain") },
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
    val generatedNpub by viewModel.generatedNpub.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()

    // Read from the view model, so Back from the password page shows the
    // same key instead of offering to make a new one.
    val nsec = generatedNsec
    if (nsec != null) {
        NewKeysPage(npub = generatedNpub.orEmpty(), nsec = nsec, onContinue = viewModel::advanceFromNostrIntro)
        return
    }

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

/**
 * Both new keys explained, the nsec readable in full to write down, and
 * Continue held until "I saved my secret key" is ticked. Tapping a card
 * copies it. Same as iOS (#399).
 */
@Composable
private fun NewKeysPage(npub: String, nsec: String, onContinue: () -> Unit) {
    val context = LocalContext.current
    var savedKey by remember { mutableStateOf(false) }
    var copiedKey by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(copiedKey) {
        if (copiedKey != null) {
            kotlinx.coroutines.delay(1_500)
            copiedKey = null
        }
    }
    fun copy(value: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val clip = android.content.ClipData.newPlainText("Nostr key", value)
        // Keeps the nsec out of the clipboard preview (Android 13+).
        if (value == nsec) {
            clip.description.extras = android.os.PersistableBundle().apply {
                putBoolean("android.content.extra.IS_SENSITIVE", true)
            }
        }
        clipboard.setPrimaryClip(clip)
        copiedKey = value
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Your Keys", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Two keys replace a username and password.",
            color = SecondaryText,
            fontSize = 15.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(14.dp))
        NewKeyCard(
            icon = Icons.Default.Person,
            title = "Public key",
            caption = "Your name on Nostr. Share it freely.",
            value = npub,
            isSecret = false,
            copied = copiedKey == npub,
            onCopy = { copy(npub) },
        )
        Spacer(Modifier.height(14.dp))
        NewKeyCard(
            icon = Icons.Default.Key,
            title = "Secret key",
            caption = "Your password to Nostr. Anyone who has it can post as you, so never share it.",
            value = nsec,
            isSecret = true,
            copied = copiedKey == nsec,
            onCopy = { copy(nsec) },
        )
        Spacer(Modifier.height(8.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .toggleable(value = savedKey, role = Role.Checkbox, onValueChange = { savedKey = it }),
        ) {
            Checkbox(
                checked = savedKey,
                onCheckedChange = null,
                colors = CheckboxDefaults.colors(checkedColor = WizardAccent, uncheckedColor = SecondaryText),
            )
            Spacer(Modifier.width(10.dp))
            Text("I saved my secret key", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.height(8.dp))
        WizardPrimaryButton(text = "Continue", enabled = savedKey, onClick = onContinue)
    }
}

@Composable
private fun NewKeyCard(
    icon: ImageVector,
    title: String,
    caption: String,
    value: String,
    isSecret: Boolean,
    copied: Boolean,
    onCopy: () -> Unit,
) {
    WizardCard(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClickLabel = "Copy $title", onClick = onCopy),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = if (isSecret) WizardAccent else SecondaryText, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(title, color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(
                text = if (copied) "Copied" else "Copy",
                color = if (copied) SuccessGreen else WizardAccent,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(caption, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp)
        Spacer(Modifier.height(8.dp))
        Text(
            text = value,
            color = if (isSecret) WizardAccent else SecondaryText,
            fontSize = 12.sp,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            // The npub only needs recognising; the nsec has to be readable in
            // full to write it down.
            maxLines = if (isSecret) Int.MAX_VALUE else 1,
            overflow = if (isSecret) TextOverflow.Clip else TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(WizardBgElevated)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(8.dp))
                .padding(10.dp),
        )
        if (isSecret) {
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Default.Shield, contentDescription = null, tint = PrimaryText.copy(alpha = 0.85f), modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text(
                    "Nobody can recover it for you, not even us.",
                    color = PrimaryText.copy(alpha = 0.85f),
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                )
            }
        }
    }
}

/**
 * The password that encrypts the new nsec (NIP-49). Its own page so the
 * fields sit above the keyboard without scrolling. While a field has focus
 * the icon and subtitle step aside. Same as iOS (#399).
 */
@Composable
private fun KeyPasswordStep(viewModel: SetupWizardViewModel) {
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val passphrase by viewModel.passphrase.collectAsState()
    val confirmPassphrase by viewModel.confirmPassphrase.collectAsState()
    var showPassword by remember { mutableStateOf(false) }
    var passwordFocused by remember { mutableStateOf(false) }
    var confirmFocused by remember { mutableStateOf(false) }
    val isTyping = passwordFocused || confirmFocused
    val confirmFocus = remember { FocusRequester() }
    val isPasswordValid = passphrase.length >= 8 && passphrase == confirmPassphrase

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        AnimatedVisibility(visible = !isTyping) {
            Icon(
                Icons.Default.Lock,
                contentDescription = null,
                tint = WizardAccent,
                modifier = Modifier.padding(bottom = 8.dp).size(40.dp),
            )
        }
        Text("Protect Your Key", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        AnimatedVisibility(visible = !isTyping) {
            Text(
                text = "Choose a password to lock your secret key on this phone.",
                color = SecondaryText,
                fontSize = 15.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Spacer(Modifier.height(20.dp))

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
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Next),
            keyboardActions = KeyboardActions(onNext = { confirmFocus.requestFocus() }),
            colors = wizardTextFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { passwordFocused = it.isFocused },
        )
        Spacer(Modifier.height(8.dp))
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
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = {
                if (isPasswordValid && !isLoading) viewModel.advanceFromKeyPassword()
            }),
            colors = wizardTextFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(confirmFocus)
                .onFocusChanged { confirmFocused = it.isFocused },
        )

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = ErrorRed, fontSize = 13.sp)
        }

        // Above the warning so it stays above the keyboard while typing; the
        // warning was already read before a field took focus.
        Spacer(Modifier.height(16.dp))
        WizardPrimaryButton(
            text = "Continue",
            enabled = isPasswordValid,
            isLoading = isLoading,
            onClick = viewModel::advanceFromKeyPassword,
        )
        Spacer(Modifier.height(16.dp))
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(WizardAccent.copy(alpha = 0.08f))
                .border(1.dp, WizardBorderActive, RoundedCornerShape(12.dp))
                .padding(14.dp)
                .semantics(mergeDescendants = true) {},
        ) {
            Icon(Icons.Default.Shield, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                "Nobody can reset this password or recover your secret key for you, not even us. Write both down.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
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
                    NostrConnectPairing(
                        accent = WizardAccent,
                        onPaired = { request, signerPubkey -> viewModel.pairNostrConnect(request, signerPubkey) },
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "Or paste or scan the bunker:// string your signer gives you. Your key stays with the signer -- Nostr Vault never sees it.",
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

    // Importing can run 20+ minutes; don't let the screen dim or lock while it's up.
    val view = LocalView.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

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
    /** "I already use Nostr" with only a public key. */
    readOnly: Boolean,
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
                    // How the on-device relay and Blossom reach everyone else.
                    Column(
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(WizardBgElevated)
                            .border(1.dp, WizardBorderSubtle, RoundedCornerShape(12.dp))
                            .padding(16.dp),
                    ) {
                        CompleteExplainerRow(
                            Icons.Default.CellTower,
                            "Your relay lives on this phone and sends your posts out to public relays so people can see them.",
                        )
                        CompleteExplainerRow(
                            Icons.Default.PhotoLibrary,
                            "Blossom does the same for photos and videos: they're kept here and copied to public media servers.",
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "Next, a short guide helps you find people to follow.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                SetupPath.USE_NOSTR -> {
                    WizardCheckItem(if (readOnly) "Connected to Nostr" else "Signed in")
                    WizardCheckItem("Using your relay")
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = if (readOnly) "Read-only for now. Add your private key in Settings to post."
                        else "Your posts go out through the relay you chose.",
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
private fun CompleteExplainerRow(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(text, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp)
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
internal fun WizardCard(
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
internal fun WizardPrimaryButton(
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
internal fun WizardSecondaryButton(
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
// Step: Profile (New to Nostr)
// ══════════════════════════════════════════════════════════════════

@Composable
private fun ProfileStep(viewModel: SetupWizardViewModel) {
    val name by viewModel.profileName.collectAsState()
    val photo by viewModel.profilePhotoJpeg.collectAsState()
    val photoError by viewModel.profilePhotoError.collectAsState()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) viewModel.setProfilePhoto(uri)
    }
    val preview = remember(photo) {
        photo?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = "Your Profile",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "This is how people will see you. You can change it later.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 22.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .clip(RoundedCornerShape(12.dp))
                .clickable(onClickLabel = if (photo == null) "Add profile photo" else "Change profile photo") {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
                .padding(8.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(104.dp)
                    .clip(CircleShape)
                    .background(WizardBgElevated)
                    .border(1.dp, WizardAccent, CircleShape),
            ) {
                if (preview != null) {
                    androidx.compose.foundation.Image(
                        bitmap = preview,
                        contentDescription = "Profile photo",
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Default.PhotoCamera,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = if (photo == null) "Add Photo" else "Change Photo",
                color = WizardAccent,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        photoError?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = SecondaryText, fontSize = 13.sp)
        }

        Spacer(Modifier.height(20.dp))
        OutlinedTextField(
            value = name,
            onValueChange = viewModel::setProfileName,
            label = { Text("Name") },
            placeholder = { Text("Your name") },
            singleLine = true,
            colors = wizardTextFieldColors(),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(24.dp))
        WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromProfile)
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = viewModel::skipProfile) {
            Text("Skip for Now", color = SecondaryText, fontSize = 14.sp)
        }
    }
}


@Composable
internal fun wizardTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = WizardAccent,
    unfocusedBorderColor = WizardBorderSubtle,
    cursorColor = WizardAccent,
    focusedLabelColor = WizardAccent,
)
