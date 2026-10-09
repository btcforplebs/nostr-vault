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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
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
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.LNURLPayResponse
import com.nostrvault.service.LNURLService
import com.nostrvault.service.LNURLWithdrawResponse
import com.nostrvault.service.NWCService
import com.nostrvault.service.NWCTimeoutException
import com.nostrvault.service.NWCWalletException
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapHistoryService
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.util.ZapDetail
import kotlinx.coroutines.CancellationException
import com.nostrvault.ui.screens.wallet.WalletLightningTab
import com.nostrvault.ui.theme.*
import com.nostrvault.util.Bolt11
import com.nostrvault.util.WalletTransaction
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.asStateFlow
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
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    /** Whose tutorials the wallet's cards count against. */
    val activeHexPubkey: String get() = nostrService.activeHexPubkey
    private val _lightningBalance = MutableStateFlow<Long?>(null)
    val lightningBalance = _lightningBalance.asStateFlow()

    private val _taprootAddress = MutableStateFlow<String?>(null)
    val taprootAddress = _taprootAddress.asStateFlow()

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

    init {
        refreshBalance()
        if (config.value.showBitcoinWallet) deriveAddress()
    }

    // ── Config setters (Settings tab) ─────────────────────────────
    fun setNwcUri(uri: String) = configStore.update { it.copy(nwcURI = uri.ifBlank { null }) }
    fun setDefaultZap(sats: Int) = configStore.update { it.copy(defaultZapAmount = sats.coerceAtLeast(1)) }

    fun toggleBitcoin(on: Boolean) {
        configStore.update { it.copy(showBitcoinWallet = on) }
        if (on) deriveAddress() else _taprootAddress.value = null
    }

    fun refreshBalance() {
        viewModelScope.launch {
            // NWC get_balance returns millisats (NIP-47); display as sats like iOS.
            _lightningBalance.value = try { nwcService.getBalance() / 1000 } catch (_: Exception) { null }
        }
    }

    private fun deriveAddress() {
        val hex = nostrService.ownerHexPubkey
        if (hex.isNotEmpty()) _taprootAddress.value = HavenBridge.deriveTaprootAddress(hex)
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
    onSweep: () -> Unit = {},
    onNoteClick: (String) -> Unit = {},
    viewModel: WalletViewModel = hiltViewModel(),
) {
    var selectedTab by remember { mutableStateOf(WalletTab.LIGHTNING) }
    val error by viewModel.error.collectAsState()
    val message by viewModel.message.collectAsState()
    val snackbarHost = remember { SnackbarHostState() }

    LaunchedEffect(error, message) {
        (error ?: message)?.let {
            snackbarHost.showSnackbar(it)
            viewModel.clearMessages()
        }
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
        snackbarHost = { SnackbarHost(snackbarHost) },
        containerColor = WindowBackground,
    ) { padding ->
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
                WalletTab.SETTINGS -> WalletSettingsTab(viewModel, onSweep)
            }
        }
    }
}

@Composable
private fun WalletSettingsTab(viewModel: WalletViewModel, onSweep: () -> Unit) {
    val config by viewModel.config.collectAsState()
    val taproot by viewModel.taprootAddress.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        WalletSectionLabel("Nostr Wallet Connect (NWC)")
        OutlinedTextField(
            value = config.nwcURI ?: "",
            onValueChange = viewModel::setNwcUri,
            placeholder = { Text("nostr+walletconnect://…") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            colors = walletFieldColors(colors.primary),
        )
        WalletCaption("Connect a Lightning wallet to send zaps and use the Lightning tab.")

        if (!config.nwcURI.isNullOrBlank()) {
            Spacer(Modifier.height(8.dp))
            var zapText by remember(config.defaultZapAmount) { mutableStateOf(config.defaultZapAmount.toString()) }
            OutlinedTextField(
                value = zapText,
                onValueChange = { t -> zapText = t.filter { it.isDigit() }; zapText.toIntOrNull()?.let(viewModel::setDefaultZap) },
                label = { Text("Default Zap Amount (sats)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
                colors = walletFieldColors(colors.primary),
            )
        }

        Spacer(Modifier.height(24.dp))

        WalletSectionLabel("Bitcoin")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Bitcoin Address", color = PrimaryText, fontSize = 15.sp)
                Text("Derive a taproot address from your Nostr key (BIP-341)", color = SecondaryText, fontSize = 12.sp)
            }
            Switch(
                checked = config.showBitcoinWallet,
                onCheckedChange = viewModel::toggleBitcoin,
                colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
            )
        }

        if (config.showBitcoinWallet && taproot != null) {
            Spacer(Modifier.height(12.dp))
            WalletQr(taproot!!)
            Spacer(Modifier.height(8.dp))
            Text(taproot!!, color = PrimaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            Spacer(Modifier.height(8.dp))
            Row {
                OutlinedButton(onClick = { clipboard.setText(AnnotatedString(taproot!!)) }) {
                    Text("Copy Address")
                }
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = onSweep,
                    colors = ButtonDefaults.buttonColors(containerColor = ZapOrange),
                ) { Text("Sweep Wallet") }
            }
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
internal fun WalletSectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = Modifier.padding(bottom = 8.dp),
    )
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
