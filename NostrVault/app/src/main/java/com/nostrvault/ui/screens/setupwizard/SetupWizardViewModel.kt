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
    WELCOME, RELAY_CHOICE, NOSTR_INTRO, KEY_PASSWORD, PROFILE, USE_NOSTR_KEY, REFERRER, RELAY_CHECK, IMPORT_TOUR,
    ACCOUNT, RELAYS, IMPORT_NOTES, MIRROR_MEDIA, WALLET, NOTIFICATIONS, COMPLETE
}

enum class AccountMode { GENERATE, IMPORT, AMBER, REMOTE_SIGNER }
/** [USE_NOSTR] is "I already use Nostr": one key field decides read-only vs
 *  can-post, so it replaces [FULL] and [BROWSE] on the front door. Same as iOS. */
enum class SetupPath { NONE, FULL, BROWSE, NEW_TO_NOSTR, USE_NOSTR }

// ── ViewModel ────────────────────────────────────────────────────

@HiltViewModel
class SetupWizardViewModel @Inject constructor(
    internal val configStore: ConfigStore,
    internal val credentialStore: CredentialStore,
    internal val amberSignerService: AmberSignerService,
    internal val blossomService: BlossomService,
    internal val nostrService: NostrService,
    internal val relayImportService: RelayImportService,
    internal val statsService: StatsService,
    @ApplicationContext internal val appContext: Context,
) : ViewModel() {

    // Navigation
    internal val _step = MutableStateFlow(WizardStep.WELCOME)
    val step = _step.asStateFlow()

    internal val _setupPath = MutableStateFlow(SetupPath.NONE)
    val setupPath = _setupPath.asStateFlow()

    // Relay choice: the built-in relay, or a relay app already on the phone
    internal val _useExternalRelay = MutableStateFlow(false)
    val useExternalRelay = _useExternalRelay.asStateFlow()

    internal val _externalRelayInput = MutableStateFlow("")
    val externalRelayInput = _externalRelayInput.asStateFlow()

    internal val _externalBlossomInput = MutableStateFlow("")
    val externalBlossomInput = _externalBlossomInput.asStateFlow()

    // Account
    internal val _accountMode = MutableStateFlow(AccountMode.GENERATE)
    val accountMode = _accountMode.asStateFlow()

    internal val _npubInput = MutableStateFlow("")
    val npubInput = _npubInput.asStateFlow()

    internal val _nsecInput = MutableStateFlow("")
    val nsecInput = _nsecInput.asStateFlow()

    internal val _bunkerInput = MutableStateFlow("")
    val bunkerInput = _bunkerInput.asStateFlow()

    internal val _passphrase = MutableStateFlow("")
    val passphrase = _passphrase.asStateFlow()

    internal val _confirmPassphrase = MutableStateFlow("")
    val confirmPassphrase = _confirmPassphrase.asStateFlow()

    internal val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    internal val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    internal val _generatedNsec = MutableStateFlow<String?>(null)
    val generatedNsec = _generatedNsec.asStateFlow()

    internal val _generatedSkHex = MutableStateFlow<String?>(null)

    private val _isAmberAvailable = MutableStateFlow(false)
    val isAmberAvailable = _isAmberAvailable.asStateFlow()

    // Relays
    internal val _wizardRelays = MutableStateFlow(HavenConfig.DEFAULT_READ_RELAYS)
    val wizardRelays = _wizardRelays.asStateFlow()

    internal val _newRelayInput = MutableStateFlow("")
    val newRelayInput = _newRelayInput.asStateFlow()

    internal val _macRelayInput = MutableStateFlow("")
    val macRelayInput = _macRelayInput.asStateFlow()

    // Import
    internal val _importStartDate = MutableStateFlow("2023-01-01")
    val importStartDate = _importStartDate.asStateFlow()

    internal val _isImporting = MutableStateFlow(false)
    val isImporting = _isImporting.asStateFlow()

    internal val _importProgress = MutableStateFlow(-1f) // -1 = indeterminate
    val importProgress = _importProgress.asStateFlow()

    internal val _importStatus = MutableStateFlow("")
    val importStatus = _importStatus.asStateFlow()

    internal val _importCompleted = MutableStateFlow(false)
    val importCompleted = _importCompleted.asStateFlow()

    // Blossom
    internal val _blossomURL = MutableStateFlow("https://blossom.primal.net")
    val blossomURL = _blossomURL.asStateFlow()

    internal val _isMirroring = MutableStateFlow(false)
    val isMirroring = _isMirroring.asStateFlow()

    internal val _mirrorProgress = MutableStateFlow(-1f)
    val mirrorProgress = _mirrorProgress.asStateFlow()

    internal val _mirrorStatus = MutableStateFlow("")
    val mirrorStatus = _mirrorStatus.asStateFlow()

    internal val _mirrorCompleted = MutableStateFlow(false)
    val mirrorCompleted = _mirrorCompleted.asStateFlow()

    // Wallet
    internal val _nwcInput = MutableStateFlow("")
    val nwcInput = _nwcInput.asStateFlow()


    // New account: published once setup completes (see publishNewAccount)
    internal val _profileName = MutableStateFlow("")
    val profileName = _profileName.asStateFlow()

    internal val _profilePhotoJpeg = MutableStateFlow<ByteArray?>(null)
    val profilePhotoJpeg = _profilePhotoJpeg.asStateFlow()

    internal val _profilePhotoError = MutableStateFlow<String?>(null)
    val profilePhotoError = _profilePhotoError.asStateFlow()

    /** The new account's npub, shown on the keys page beside the nsec. */
    internal val _generatedNpub = MutableStateFlow<String?>(null)
    val generatedNpub = _generatedNpub.asStateFlow()
    /** The pubkey New to Nostr generated this run. Only this key may be
     *  marked fresh or have a profile published for it at the end. */
    internal var generatedPkHex: String? = null

    /** Keys this run of setup stored that weren't on the device before, so a
     *  key left behind by Back and another choice can be removed again. */
    internal val wizardStoredKeys = mutableSetOf<String>()

    // I already use Nostr
    internal val _useNostrInput = MutableStateFlow("")
    val useNostrInput = _useNostrInput.asStateFlow()

    internal val _useNostrPassword = MutableStateFlow("")
    val useNostrPassword = _useNostrPassword.asStateFlow()

    internal val _useNostrConfirm = MutableStateFlow("")
    val useNostrConfirm = _useNostrConfirm.asStateFlow()

    internal val _relayRows = MutableStateFlow<List<RelayCheck.Row>>(emptyList())
    val relayRows = _relayRows.asStateFlow()

    internal val _isCheckingRelays = MutableStateFlow(true)
    val isCheckingRelays = _isCheckingRelays.asStateFlow()
    /** The account the rows were checked for; another key checks again. */
    internal var relayCheckPubkey: String? = null

    /** The import tour runs the app-wide import, so it outlives this screen. */
    val tourIsImporting = relayImportService.isImporting
    val tourImportCompleted = relayImportService.importCompleted
    val tourImportProgress = relayImportService.importProgress
    val tourImportStatus = relayImportService.importStatusMessage

    /** Notes, likes and everything, read from the relay once the import is done. */
    internal val _tourCounts = MutableStateFlow<Triple<Int, Int, Int>?>(null)
    val tourCounts = _tourCounts.asStateFlow()
    /** The account whose import the tour started. */
    internal var importTourPubkey: String? = null

    /** The tour's import ran and stopped without finishing. Kept here, not in
     *  the screen, so leaving and returning to the step still knows. */
    internal val _tourImportFailed = MutableStateFlow(false)
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
            val steps = withReferrerStep(
                when (_setupPath.value) {
                    SetupPath.BROWSE -> browseSteps
                    SetupPath.NEW_TO_NOSTR -> newUserSteps
                    SetupPath.USE_NOSTR -> useNostrSteps
                    else -> fullSteps
                },
                _setupPath.value,
                readOnly = configStore.config.value.setupMode == "browse",
            )
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
    internal fun stepAfter(step: WizardStep): WizardStep {
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
        com.nostrvault.setup.ReferrerFollows.clear()
        _setupPath.value = path
        _step.value = WizardStep.RELAY_CHOICE
    }
}
