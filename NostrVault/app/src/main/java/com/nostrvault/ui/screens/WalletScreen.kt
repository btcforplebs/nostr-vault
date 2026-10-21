package com.nostrvault.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.LNURLPayResponse
import com.nostrvault.service.LNURLService
import com.nostrvault.service.LNURLWithdrawResponse
import com.nostrvault.service.NWCService
import com.nostrvault.service.NWCTimeoutException
import com.nostrvault.service.NWCWalletException
import com.nostrvault.service.NostrService
import com.nostrvault.service.NwcBackupService
import com.nostrvault.data.model.NwcBackup
import com.nostrvault.service.ZapHistoryService
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.util.ZapDetail
import kotlinx.coroutines.CancellationException
import com.nostrvault.ui.screens.wallet.WalletLightningTab
import com.nostrvault.ui.screens.settings.InfoButton
import com.nostrvault.ui.screens.settings.SettingsHelp
import com.nostrvault.ui.theme.*
import com.nostrvault.util.Bolt11
import com.nostrvault.util.WalletTransaction
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
doc
 */
@HiltViewModel
class WalletViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nwcService: NWCService,
    private val nostrService: NostrService,
    private val zapHistoryService: ZapHistoryService,
    private val nwcBackupService: NwcBackupService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    /** Whose tutorials the wallet's cards count against. */
    val activeHexPubkey: String get() = nostrService.activeHexPubkey
    private val _lightningBalance = MutableStateFlow<Long?>(null)
    val lightningBalance = _lightningBalance.asStateFlow()

    // Shared operation state
    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)
    val message = _message.asStateFlow()

    // Lightning receive
    private val _generatedInvoice = MutableStateFlow<String?>(null)
    val generatedInvoice = _generatedInvoice.asStateFlow()

    // Lightning history (NIP-47 list_transactions)
    private val _transactions = MutableStateFlow<List<WalletTransaction>>(emptyList())
    val transactions = _transactions.asStateFlow()

    private val _historyLoading = MutableStateFlow(false)
    val historyLoading = _historyLoading.asStateFlow()

    private val _historyError = MutableStateFlow<String?>(null)
    val historyError = _historyError.asStateFlow()

    /** The wallet, or this connection's permissions, does not share history. */
    private val _historyUnsupported = MutableStateFlow(false)
    val historyUnsupported = _historyUnsupported.asStateFlow()

    private val _canLoadMoreHistory = MutableStateFlow(false)
    val canLoadMoreHistory = _canLoadMoreHistory.asStateFlow()

    /** Who each zap in the history came from, keyed by transaction id. */
    private val _zapDetails = MutableStateFlow<Map<String, ZapDetail>>(emptyMap())
    val zapDetails = _zapDetails.asStateFlow()

    /** The zapped posts, keyed by post id. */
    private val _zapPosts = MutableStateFlow<Map<String, FeedNote>>(emptyMap())
    val zapPosts = _zapPosts.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    val myPubkey: String get() = nostrService.activeHexPubkey

    /** A refresh asked for while a page was loading; it runs once that page lands. */
    private var historyRefreshPending = false

    // Wallet slot on this Nostr account (NIP-78, Wisp's format), and whose
    // account it was read for: an action on another account's state would
    // publish into the wrong slot.
    private val _backupStatus = MutableStateFlow<NwcBackup.Status>(NwcBackup.Status.Unknown)
    val backupStatus = _backupStatus.asStateFlow()
    private var backupStatusAccount = ""

    private val _backupChecked = MutableStateFlow(false)
    val backupChecked = _backupChecked.asStateFlow()

    private val _backupBusy = MutableStateFlow(false)
    val backupBusy = _backupBusy.asStateFlow()

    private val _backupError = MutableStateFlow<String?>(null)
    val backupError = _backupError.asStateFlow()

    init {
        refreshBalance()
        // Re-read on every account switch, as iOS keys on the active pubkey.
        viewModelScope.launch {
            configStore.config.map { it.activeOrOwnerNpub() }.distinctUntilChanged().collect {
                refreshBackupStatus(askSigner = false)
            }
        }
    }

    /** Reads the slot again; [askSigner] lets the signer decrypt (the user tapped). */
    fun refreshBackupStatus(askSigner: Boolean) {
        val account = nostrService.activeHexPubkey
        if (account != backupStatusAccount) {
            _backupStatus.value = NwcBackup.Status.Unknown
            _backupChecked.value = false
        }
        backupStatusAccount = account
        viewModelScope.launch {
            if (askSigner) _backupBusy.value = true
            val status = nwcBackupService.status(account, askSigner)
            // A switch while the lookup ran: that answer belongs to someone else.
            if (nostrService.activeHexPubkey == account) {
                _backupStatus.value = status
                _backupChecked.value = true
            }
            if (askSigner) _backupBusy.value = false
        }
    }

    /** Puts the wallet saved on this account into use. */
    fun useSavedWallet() {
        val saved = _backupStatus.value as? NwcBackup.Status.Saved ?: return
        setNwcUri(saved.uri)
    }

    /**
     * The "Save wallet to my Nostr account" switch (on saves the wallet in use)
     * and "Remove from my account" (off). Locked to the account the screen
     * shows, all the way to publishing.
     */
    fun setSaveToAccount(on: Boolean) {
        if (_backupBusy.value) return
        val lock = nostrService.lockPostingAccount()
        if (lock.hex != backupStatusAccount) {
            _backupError.value = "The account changed. Nothing was published; check again."
            refreshBackupStatus(askSigner = false)
            return
        }
        val uri = config.value.nwcURI.orEmpty()
        viewModelScope.launch {
            _backupBusy.value = true
            _backupError.value = null
            val problem = if (on) nwcBackupService.save(uri, lock) else nwcBackupService.clear(lock)
            if (problem != null) {
                _backupError.value = problem
            } else if (nostrService.activeHexPubkey == lock.hex) {
                // Only the account it was done for gets the new state.
                _backupStatus.value = if (on) {
                    NwcBackup.plaintextForSaving(uri)?.let { NwcBackup.Status.Saved(it, System.currentTimeMillis() / 1000) }
                        ?: _backupStatus.value
                } else {
                    NwcBackup.Status.Empty
                }
            }
            _backupBusy.value = false
        }
    }

    // ── Config setters (Settings tab) ─────────────────────────────
    fun setNwcUri(uri: String) = configStore.update { it.copy(nwcURI = uri.ifBlank { null }) }
    fun setDefaultZap(sats: Int) = configStore.update { it.copy(defaultZapAmount = sats.coerceAtLeast(1)) }

    fun refreshBalance() {
        viewModelScope.launch {
            // NWC get_balance returns millisats (NIP-47); display as sats like iOS.
            _lightningBalance.value = try { nwcService.getBalance() / 1000 } catch (_: Exception) { null }
        }
    }

    fun clearMessages() { _error.value = null; _message.value = null }

    // ── Lightning operations ──────────────────────────────────────
    fun createInvoice(amountSats: Long, description: String) {
        if (amountSats <= 0 || _busy.value) return
        viewModelScope.launch {
            _busy.value = true; _error.value = null
            try {
                _generatedInvoice.value = nwcService.makeInvoice(amountSats * 1000, description.ifBlank { null })
            } catch (e: Exception) {
                _error.value = e.message ?: "Could not create invoice"
            } finally { _busy.value = false }
        }
    }

    fun clearInvoice() { _generatedInvoice.value = null }

    fun payInvoice(bolt11: String) {
        val invoice = bolt11.trim()
        if (invoice.isEmpty() || _busy.value) return
        viewModelScope.launch {
            _busy.value = true; _error.value = null; _message.value = null
            try {
                nwcService.payInvoice(invoice)
                _message.value = "Payment sent"
                refreshBalance()
                loadHistory(reset = true)
            } catch (e: Exception) {
                _error.value = e.message ?: "Payment failed"
            } finally { _busy.value = false }
        }
    }

    /**
     * Pays a resolved LNURL-pay / lightning address. [onSent] runs only once
     * the payment went through, so the Send box keeps its text on failure.
     */
    fun payLnurl(
        pay: LNURLPayResponse,
        amountMsat: Long,
        recipient: String,
        comment: String,
        onSent: () -> Unit,
    ) {
        if (_busy.value) return
        val sats = amountMsat / 1000
        viewModelScope.launch {
            _busy.value = true; _error.value = null; _message.value = null
            var unconfirmed = false
            try {
                val invoice = LNURLService.fetchInvoice(
                    callback = pay.callback,
                    amountMsat = amountMsat,
                    comment = comment.trim().ifEmpty { null },
                )
                // LUD-06: never pay an invoice for a different amount than the
                // one asked for — a service that swaps it is either broken or
                // stealing. Exact msat: whole sats would let it add up to 999.
                if (Bolt11.msat(invoice) != amountMsat) {
                    _error.value = "$recipient returned an invoice for a different amount, so nothing was sent."
                    return@launch
                }
                try {
                    nwcService.payInvoice(invoice)
                } catch (e: NWCTimeoutException) {
                    // The request reached the relay and the wallet may be paying
                    // right now. Retrying would fetch a NEW invoice from the
                    // service and pay twice, so clear the form instead of
                    // leaving Send one tap away.
                    unconfirmed = true
                    _error.value = "Your wallet didn't confirm in time. The payment may still go " +
                        "through, so check History before sending again."
                    onSent()
                    return@launch
                }
                _message.value = "Sent ${"%,d".format(sats)} sats to $recipient."
                onSent()
                refreshBalance()
                loadHistory(reset = true)
            } catch (e: Exception) {
                _error.value = e.message ?: "Payment failed"
            } finally {
                _busy.value = false
                if (unconfirmed) {
                    // Look again once a late settlement has had a moment to land.
                    viewModelScope.launch {
                        delay(5_000)
                        refreshBalance()
                        loadHistory(reset = true)
                    }
                }
            }
        }
    }

    /** LNURL-withdraw: make an invoice on our wallet and hand it to the service. */
    fun withdrawLnurl(
        withdraw: LNURLWithdrawResponse,
        amountMsat: Long,
        sender: String,
        onReceived: () -> Unit,
    ) {
        if (_busy.value) return
        val sats = amountMsat / 1000
        viewModelScope.launch {
            _busy.value = true; _error.value = null; _message.value = null
            try {
                val invoice = nwcService.makeInvoice(amountMsat, withdraw.defaultDescription)
                LNURLService.submitWithdraw(withdraw, invoice)
                _message.value = "$sender is sending you ${"%,d".format(sats)} sats. " +
                    "It shows up in History once it lands."
                onReceived()
            } catch (e: Exception) {
                _error.value = e.message ?: "Withdrawal failed"
                return@launch
            } finally { _busy.value = false }
            // The service pays asynchronously; look again once it has had a moment.
            delay(4_000)
            refreshBalance()
            loadHistory(reset = true)
        }
    }

    // ── History ───────────────────────────────────────────────────
    fun loadHistory(reset: Boolean) {
        if (config.value.nwcURI.isNullOrBlank()) return
        if (_historyLoading.value) {
            // A payment just finished while a page was loading: refresh after.
            if (reset) historyRefreshPending = true
            return
        }
        _historyLoading.value = true
        _historyError.value = null
        val offset = if (reset) 0 else _transactions.value.size
        viewModelScope.launch {
            try {
                val page = nwcService.listTransactions(limit = HISTORY_PAGE_SIZE, offset = offset)
                _transactions.value = if (reset) page else WalletTransaction.merge(_transactions.value, page)
                resolveZaps(page)
                _canLoadMoreHistory.value = page.size >= HISTORY_PAGE_SIZE
                _historyUnsupported.value = false
            } catch (e: NWCWalletException) {
                if (e.isUnsupported) _historyUnsupported.value = true
                else _historyError.value = "Couldn't load history: ${e.message}"
            } catch (e: Exception) {
                _historyError.value = "Couldn't load history: ${e.message}"
            } finally { _historyLoading.value = false }
            if (historyRefreshPending) {
                historyRefreshPending = false
                loadHistory(reset = true)
            }
        }
    }

    /** Looks up who each zap on this page came from, without holding up the list. */
    private fun resolveZaps(page: List<WalletTransaction>) {
        val me = nostrService.activeHexPubkey
        viewModelScope.launch {
            val found = try {
                zapHistoryService.lookup(page, me)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                return@launch
            }
            _zapDetails.value = _zapDetails.value + found.details
            _zapPosts.value = _zapPosts.value + found.posts
        }
    }

    private companion object {
        const val HISTORY_PAGE_SIZE = 20
    }

}

private enum class WalletTab(val label: String) { LIGHTNING("Lightning"), SETTINGS("Settings") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WalletScreen(
    onBack: () -> Unit,
    onNoteClick: (String) -> Unit = {},
    // Settings > Wallet opens only the settings, as iOS WalletSettingsView;
    // sending stays behind Profile.
    settingsOnly: Boolean = false,
    viewModel: WalletViewModel = hiltViewModel(),
) {
    var selectedTab by remember { mutableStateOf(WalletTab.LIGHTNING) }
    val error by viewModel.error.collectAsState()
    val message by viewModel.message.collectAsState()
    // Payments report in the lane, not a Snackbar (docs/pills.md).
    val lane = com.nostrvault.ui.notification.LocalNotificationManager.current
    LaunchedEffect(error, message) {
        if (error == null && message == null) return@LaunchedEffect
        error?.let { lane.showError(it) }
        message?.let { lane.showToast(it) }
        viewModel.clearMessages()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Wallet", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        if (settingsOnly) {
            Column(modifier = Modifier.fillMaxSize().padding(padding)) { WalletSettingsTab(viewModel) }
            return@Scaffold
        }
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            TabRow(
                selectedTabIndex = selectedTab.ordinal,
                containerColor = WindowBackground,
                contentColor = LocalNostrVaultColors.current.primary,
            ) {
                WalletTab.entries.forEach { tab ->
                    Tab(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        text = { Text(tab.label) },
                    )
                }
            }

            when (selectedTab) {
                WalletTab.LIGHTNING -> WalletLightningTab(
                    viewModel,
                    onNoteClick,
                    onConnectWallet = { selectedTab = WalletTab.SETTINGS },
                )
                WalletTab.SETTINGS -> WalletSettingsTab(viewModel)
            }
        }
    }
}

/** The wallet saved on the Nostr account: offer, switch, signer load, remove. iOS accountBackupSection. */
@Composable
private fun AccountBackupSection(viewModel: WalletViewModel, current: String) {
    val status by viewModel.backupStatus.collectAsState()
    val busy by viewModel.backupBusy.collectAsState()
    val error by viewModel.backupError.collectAsState()
    val colors = LocalNostrVaultColors.current
    val day = status.savedAt?.let {
        java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(it * 1000))
    }.orEmpty()

    @Composable
    fun SaveSwitch(on: Boolean) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Save wallet to my Nostr account", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
            Switch(
                checked = on,
                onCheckedChange = viewModel::setSaveToAccount,
                enabled = !busy,
                colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
            )
        }
    }

    /** Saving needs no read: a slot this device can't read can still be replaced by the wallet in use. */
    @Composable
    fun ReplaceButton() {
        if (current.isNotEmpty()) {
            OutlinedButton(onClick = { viewModel.setSaveToAccount(true) }, enabled = !busy) { Text("Save this wallet instead") }
        }
    }

    Spacer(Modifier.height(12.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        WalletSectionLabel("Your Nostr account")
        if (busy) {
            Spacer(Modifier.width(8.dp))
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
        }
    }
    when (val s = status) {
        NwcBackup.Status.Unknown -> {
            WalletCaption("Couldn't check your Nostr account for a saved wallet.")
            OutlinedButton(onClick = { viewModel.refreshBackupStatus(askSigner = false) }) { Text("Check again") }
        }
        NwcBackup.Status.Empty -> {
            if (current.isNotEmpty()) SaveSwitch(on = false) else WalletCaption("No wallet saved on your Nostr account.")
            // One relay's answer decides "empty"; a slower one may still hold a wallet.
            OutlinedButton(onClick = { viewModel.refreshBackupStatus(askSigner = false) }, enabled = !busy) { Text("Check again") }
        }
        is NwcBackup.Status.Saved -> if (current.isEmpty()) {
            WalletCaption("Saved $day. It may have come from Nostr Vault on another device or from Wisp.")
            OutlinedButton(onClick = viewModel::useSavedWallet) { Text("Use saved wallet") }
        } else {
            SaveSwitch(on = s.uri == current)
            if (s.uri != current) WalletCaption("Your account holds a different wallet, saved $day. Turning this on replaces it.")
        }
        is NwcBackup.Status.NeedsSigner -> {
            WalletCaption("A wallet is saved on your Nostr account ($day). Your signer has to open it.")
            OutlinedButton(onClick = { viewModel.refreshBackupStatus(askSigner = true) }, enabled = !busy) { Text("Load with signer") }
            ReplaceButton()
        }
        is NwcBackup.Status.Unreadable -> {
            WalletCaption("A wallet is saved on your Nostr account ($day), but this device can't read it.")
            OutlinedButton(onClick = { viewModel.refreshBackupStatus(askSigner = true) }, enabled = !busy) { Text("Try again") }
            ReplaceButton()
        }
    }
    // Offered whenever a wallet may be on the account: removing needs no proof it is there.
    if (status.offersRemove(current)) {
        TextButton(onClick = { viewModel.setSaveToAccount(false) }, enabled = !busy) {
            Text("Remove from my account", color = MaterialTheme.colorScheme.error)
        }
    }
    WalletCaption("Stored encrypted to your key (NIP-44) on your relays, so Nostr Vault on your other devices, or Wisp, can use it. Anyone who has your key can read it and spend from this wallet.")
    error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
}

@Composable
private fun WalletSettingsTab(viewModel: WalletViewModel) {
    val config by viewModel.config.collectAsState()
    val colors = LocalNostrVaultColors.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        WalletSectionLabel("Nostr Wallet Connect (NWC)", SettingsHelp.WALLET_NWC)
        OutlinedTextField(
            value = config.nwcURI ?: "",
            onValueChange = viewModel::setNwcUri,
            placeholder = { Text("nostr+walletconnect://…") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            colors = walletFieldColors(colors.primary),
        )
        WalletCaption("Connect a Lightning wallet to send zaps and use the Lightning tab.")

        val backupChecked by viewModel.backupChecked.collectAsState()
        if (backupChecked) AccountBackupSection(viewModel, config.nwcURI?.trim().orEmpty())

        if (!config.nwcURI.isNullOrBlank()) {
            Spacer(Modifier.height(8.dp))
            var zapText by remember(config.defaultZapAmount) { mutableStateOf(config.defaultZapAmount.toString()) }
            OutlinedTextField(
                value = zapText,
                onValueChange = { t -> zapText = t.filter { it.isDigit() }; zapText.toIntOrNull()?.let(viewModel::setDefaultZap) },
                label = { Text("Default Zap Amount (sats)") },
                trailingIcon = { InfoButton(SettingsHelp.WALLET_DEFAULT_ZAP) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
        }

        Spacer(Modifier.height(32.dp))
    }
}

// ── Shared wallet UI helpers (used by the Lightning tab file) ──

@Composable
internal fun WalletQr(content: String) {
    val bitmap = remember(content) {
        runCatching {
            BarcodeEncoder().encodeBitmap(content, BarcodeFormat.QR_CODE, 480, 480)
        }.getOrNull()
    }
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = "QR code",
            modifier = Modifier.size(220.dp),
        )
    }
}

@Composable
internal fun WalletSectionLabel(text: String, help: SettingsHelp? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 8.dp)) {
        Text(
            text = text.uppercase(),
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
        )
        if (help != null) InfoButton(help)
    }
}

@Composable
internal fun WalletCaption(text: String) {
    Text(text = text, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
}

@Composable
internal fun walletFieldColors(primary: androidx.compose.ui.graphics.Color) = OutlinedTextFieldDefaults.colors(
    focusedTextColor = PrimaryText,
    unfocusedTextColor = PrimaryText,
    cursorColor = primary,
    focusedBorderColor = primary,
)
