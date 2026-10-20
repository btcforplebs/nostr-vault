package com.nostrvault.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.MempoolApiService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.NumberFormat
import javax.inject.Inject

/**
 * Bitcoin on-chain sweep: send all funds from the Nostr-derived taproot address
 * to an external address. Port of iOS BitcoinSweepView + BitcoinSweepDisclaimerView:
 * a 3-step safety disclaimer, live balance, fee-tier selection and a dust guard.
 */
data class SweepFeeEstimates(val economy: Int, val normal: Int, val fast: Int)
data class SweepSuccess(val txid: String, val amount: Long, val fee: Long)

enum class SweepFeeTier(val label: String) { ECONOMY("Economy"), NORMAL("Normal"), FAST("Fast") }

@HiltViewModel
class BitcoinSweepViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val mempoolApi: MempoolApiService,
) : ViewModel() {
    val fromAddress: String? = nostrService.ownerHexPubkey
        .takeIf { it.isNotEmpty() }
        ?.let { HavenBridge.deriveTaprootAddress(it) }

    private val _balanceSats = MutableStateFlow<Long?>(null)
    val balanceSats = _balanceSats.asStateFlow()

    private val _feeEstimates = MutableStateFlow<SweepFeeEstimates?>(null)
    val feeEstimates = _feeEstimates.asStateFlow()

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private val _success = MutableStateFlow<SweepSuccess?>(null)
    val success = _success.asStateFlow()

    init {
        refreshBalance()
        loadFees()
    }

    fun refreshBalance() {
        val addr = fromAddress ?: return
        viewModelScope.launch { _balanceSats.value = mempoolApi.fetchAddressBalanceSats(addr) }
    }

    private fun loadFees() {
        viewModelScope.launch {
            val json = withContext(Dispatchers.IO) { HavenBridge.fetchFeeEstimates() } ?: return@launch
            try {
                val o = JSONObject(json)
                _feeEstimates.value = SweepFeeEstimates(
                    economy = o.optInt("economyFee", 1).coerceAtLeast(1),
                    normal = o.optInt("halfHourFee", 5).coerceAtLeast(1),
                    fast = o.optInt("fastestFee", 10).coerceAtLeast(1),
                )
            } catch (_: Exception) {
                // leave estimates null; UI falls back to a default rate
            }
        }
    }

    fun rateFor(tier: SweepFeeTier): Int {
        val e = _feeEstimates.value ?: return 5
        return when (tier) {
            SweepFeeTier.ECONOMY -> e.economy
            SweepFeeTier.NORMAL -> e.normal
            SweepFeeTier.FAST -> e.fast
        }.coerceAtLeast(1)
    }

    fun sweep(destAddr: String, feeRate: Int) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            try {
                val nsecHex = nostrService.resolveOwnerSecretKey()
                if (nsecHex == null) {
                    _error.value = "Could not access private key. Unlock your wallet first."
                    return@launch
                }
                val json = withContext(Dispatchers.IO) {
                    HavenBridge.sweepToAddress(nsecHex, destAddr.trim(), feeRate)
                }
                parseResult(json)
            } catch (e: Exception) {
                _error.value = "Error: ${e.message}"
            } finally {
                _busy.value = false
            }
        }
    }

    private fun parseResult(json: String?) {
        if (json == null) { _error.value = "Sweep failed (no response)."; return }
        try {
            val obj = JSONObject(json)
            val err = obj.optString("error")
            if (err.isNotEmpty()) { _error.value = err; return }
            val txid = obj.optString("txid")
            if (txid.isEmpty()) { _error.value = "Sweep failed."; return }
            _success.value = SweepSuccess(
                txid = txid,
                amount = obj.optLong("amount"),
                fee = obj.optLong("fee"),
            )
        } catch (_: Exception) {
            _error.value = "Could not parse sweep response."
        }
    }
}

private fun formatSats(sats: Long): String =
    NumberFormat.getIntegerInstance().format(sats) + " sats"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BitcoinSweepScreen(
    onBack: () -> Unit,
    viewModel: BitcoinSweepViewModel = hiltViewModel(),
) {
    val busy by viewModel.busy.collectAsState()
    val error by viewModel.error.collectAsState()
    val success by viewModel.success.collectAsState()
    val balance by viewModel.balanceSats.collectAsState()
    val feeEstimates by viewModel.feeEstimates.collectAsState()

    // 0 = warning page 1, 1 = warning page 2, 2 = disclaimer, 3 = sweep form
    var step by remember { mutableStateOf(0) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sweep Bitcoin") },
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
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                success != null -> SweepSuccessView(success!!)
                step == 0 -> SweepWarningPage1(onCancel = onBack, onContinue = { step = 1 })
                step == 1 -> SweepWarningPage2(onBack = { step = 0 }, onContinue = { step = 2 })
                step == 2 -> SweepDisclaimerPage(
                    balanceLoaded = balance != null,
                    onBack = { step = 1 },
                    onProceed = { step = 3 },
                )
                else -> SweepForm(
                    balance = balance,
                    feeEstimates = feeEstimates,
                    busy = busy,
                    error = error,
                    rateFor = viewModel::rateFor,
                    onSweep = viewModel::sweep,
                )
            }
        }
    }
}

// ── Warning page 1 ───────────────────────────────────────────────
@Composable
private fun SweepWarningPage1(onCancel: () -> Unit, onContinue: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Text("⚠️", fontSize = 48.sp)
        Spacer(Modifier.height(20.dp))
        Text("Do not send to a hardware wallet.", color = PrimaryText, fontSize = 22.sp,
            fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Text("Do not send to an exchange.", color = PrimaryText, fontSize = 22.sp,
            fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(20.dp))
        Text(
            "Sweeping to a hardware wallet or exchange creates a permanent on-chain link between your Bitcoin and your Nostr identity. This cannot be undone.",
            color = SecondaryText, fontSize = 15.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.weight(1f))
        SweepSecondaryButton("Cancel", onCancel)
        Spacer(Modifier.height(12.dp))
        SweepPrimaryButton("I understand, continue", onContinue)
    }
}

// ── Warning page 2 ───────────────────────────────────────────────
@Composable
private fun SweepWarningPage2(onBack: () -> Unit, onContinue: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Text("🛡️", fontSize = 56.sp)
        Spacer(Modifier.height(24.dp))
        Text("NOT a hardware wallet.", color = ErrorRed, fontSize = 30.sp,
            fontWeight = FontWeight.Black, textAlign = TextAlign.Center)
        Spacer(Modifier.height(16.dp))
        Text("NOT an exchange.", color = ErrorRed, fontSize = 30.sp,
            fontWeight = FontWeight.Black, textAlign = TextAlign.Center)
        Spacer(Modifier.height(24.dp))
        Text(
            "If you sweep to a Ledger, Trezor, Coldcard, Coinbase, Kraken, or ANY custodial service, your Nostr npub is permanently tied to that wallet on the public blockchain. There is no way to reverse this.",
            color = SecondaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.weight(1f))
        SweepSecondaryButton("Go Back", onBack)
        Spacer(Modifier.height(12.dp))
        SweepPrimaryButton("I will NOT send to a hardware wallet or exchange", onContinue)
    }
}

// ── Disclaimer (step 2) ──────────────────────────────────────────
@Composable
private fun SweepDisclaimerPage(balanceLoaded: Boolean, onBack: () -> Unit, onProceed: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp),
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("⚠️", fontSize = 56.sp)
                Spacer(Modifier.height(12.dp))
                Text("Important Security Warning", color = PrimaryText, fontSize = 22.sp,
                    fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                Spacer(Modifier.height(6.dp))
                Text("Sweeping your wallet requires careful consideration",
                    color = SecondaryText, fontSize = 14.sp, textAlign = TextAlign.Center)
            }
            SweepWarningCard(
                title = "⛔ Do NOT Sweep to Cold Storage",
                description = "Never sweep your Bitcoin directly to a hardware wallet or cold storage address. Sweeping creates an on-chain transaction that is permanently visible to the network.",
                highlights = listOf(
                    "Your wallet address will be exposed on the blockchain",
                    "Cold wallets may not handle single sweeps correctly",
                    "This defeats the privacy purpose of the address",
                ),
                bg = ErrorRed.copy(alpha = 0.10f), border = ErrorRed.copy(alpha = 0.30f),
            )
            Spacer(Modifier.height(16.dp))
            SweepWarningCard(
                title = "⛔ Do NOT Sweep to KYC-Linked Wallets",
                description = "Never sweep your Bitcoin to an exchange, custodial wallet, or any service that has your personal information (KYC). This links your anonymous Bitcoin to your identity permanently.",
                highlights = listOf(
                    "Exchanges, banks, and centralized services have KYC",
                    "Exchanges can freeze, restrict, or seize your coins",
                    "Creates a permanent transaction record linking you to these coins",
                    "Future regulatory actions could affect your funds",
                ),
                bg = ErrorRed.copy(alpha = 0.10f), border = ErrorRed.copy(alpha = 0.30f),
            )
            Spacer(Modifier.height(16.dp))
            SweepWarningCard(
                title = "✅ Safe Sweep Destinations",
                description = "Only sweep to addresses that meet BOTH of these criteria:",
                highlights = listOf(
                    "Private self-custody address you control (not KYC-linked)",
                    "Another Nostr key you own that you've verified as a Taproot address",
                ),
                bg = SuccessGreen.copy(alpha = 0.078f), border = SuccessGreen.copy(alpha = 0.30f),
            )
            Spacer(Modifier.height(16.dp))
            SweepWarningCard(
                title = "🔒 Privacy Notice",
                description = "Sweeping your wallet reveals the entire balance on the blockchain at that moment. Consider the timing and implications for your privacy.",
                highlights = emptyList(),
                bg = InfoBlue.copy(alpha = 0.078f), border = InfoBlue.copy(alpha = 0.30f),
            )
        }
        HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
        Column(modifier = Modifier.padding(20.dp)) {
            SweepSecondaryButton("Go Back", onBack)
            Spacer(Modifier.height(12.dp))
            SweepPrimaryButton(
                text = if (balanceLoaded) "I Understand – Proceed to Sweep" else "Loading Balance…",
                onClick = onProceed,
                enabled = balanceLoaded,
            )
        }
    }
}

@Composable
private fun SweepWarningCard(
    title: String,
    description: String,
    highlights: List<String>,
    bg: Color,
    border: Color,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg, RoundedCornerShape(10.dp))
            .border(BorderStroke(1.dp, border), RoundedCornerShape(10.dp))
            .padding(14.dp),
    ) {
        Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(description, color = SecondaryText, fontSize = 13.sp)
        if (highlights.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            highlights.forEach { h ->
                Row(modifier = Modifier.padding(vertical = 3.dp)) {
                    Text("•  ", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Text(h, color = SecondaryText, fontSize = 12.sp)
                }
            }
        }
    }
}

// ── Sweep form (step 3) ──────────────────────────────────────────
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SweepForm(
    balance: Long?,
    feeEstimates: SweepFeeEstimates?,
    busy: Boolean,
    error: String?,
    rateFor: (SweepFeeTier) -> Int,
    onSweep: (String, Int) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var dest by remember { mutableStateOf("") }
    var tier by remember { mutableStateOf(SweepFeeTier.NORMAL) }

    val estimatedVsize = 111
    val currentRate = rateFor(tier)
    val estimatedFee = (estimatedVsize * currentRate).toLong()
    val sendAmount = ((balance ?: 0L) - estimatedFee).coerceAtLeast(0L)
    val canSweep = dest.isNotBlank() && sendAmount > 546 && !busy

    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
    ) {
        // Balance card
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(ZapOrange.copy(alpha = 0.10f), RoundedCornerShape(12.dp))
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Available balance", color = SecondaryText, fontSize = 12.sp)
                Text(
                    text = balance?.let { formatSats(it) } ?: "Loading…",
                    color = Color(0xFFFFBF4D), fontSize = 22.sp, fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Text("₿", fontSize = 30.sp, color = ZapOrange)
        }

        Spacer(Modifier.height(20.dp))
        Text("Destination address", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(6.dp))
        OutlinedTextField(
            value = dest,
            onValueChange = { dest = it },
            placeholder = { Text("bc1p…") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                cursorColor = colors.primary, focusedBorderColor = colors.primary,
            ),
        )

        Spacer(Modifier.height(16.dp))
        Text("Fee rate", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            SweepFeeTier.entries.forEach { t ->
                val rate = feeEstimates?.let { rateFor(t) }
                SweepFeeTierButton(
                    label = t.label,
                    rateLabel = rate?.let { "$it sat/vB" } ?: "–",
                    selected = tier == t,
                    modifier = Modifier.weight(1f),
                    onClick = { tier = t },
                )
            }
        }

        Spacer(Modifier.height(16.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(SecondaryText.copy(alpha = 0.06f), RoundedCornerShape(10.dp))
                .padding(14.dp),
        ) {
            SweepPreviewRow(
                label = "Fee ($currentRate sat/vB × ~$estimatedVsize vB)",
                value = formatSats(estimatedFee),
                color = SecondaryText,
            )
            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp), color = SecondaryText.copy(alpha = 0.15f))
            SweepPreviewRow(
                label = "You'll send",
                value = formatSats(sendAmount),
                color = if (sendAmount > 546) PrimaryText else ErrorRed,
            )
        }

        if (error != null) {
            Spacer(Modifier.height(12.dp))
            Text(error, color = ErrorRed, fontSize = 13.sp, modifier = Modifier
                .fillMaxWidth()
                .background(ErrorRed.copy(alpha = 0.078f), RoundedCornerShape(8.dp))
                .padding(10.dp))
        }

        Spacer(Modifier.height(16.dp))
        Button(
            onClick = { onSweep(dest, currentRate) },
            enabled = canSweep,
            colors = ButtonDefaults.buttonColors(containerColor = ZapOrange),
            modifier = Modifier.fillMaxWidth().height(50.dp),
        ) { Text(if (busy) "Broadcasting…" else "Sweep", fontWeight = FontWeight.SemiBold) }

        if (sendAmount in 1..546) {
            Spacer(Modifier.height(8.dp))
            Text("Insufficient funds after fees", color = SecondaryText, fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun SweepFeeTierButton(
    label: String,
    rateLabel: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Column(
        modifier = modifier
            .background(if (selected) ZapOrange else SecondaryText.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(label, color = if (selected) Color.White else SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Text(rateLabel, color = if (selected) Color.White.copy(alpha = 0.8f) else SecondaryText, fontSize = 10.sp)
    }
}

@Composable
private fun SweepPreviewRow(label: String, value: String, color: Color) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text(value, color = color, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
    }
}

// ── Success ──────────────────────────────────────────────────────
@Composable
private fun SweepSuccessView(success: SweepSuccess) {
    val uriHandler = LocalUriHandler.current
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(24.dp))
        Text("✅", fontSize = 56.sp)
        Spacer(Modifier.height(12.dp))
        Text("Swept!", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(20.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(SecondaryText.copy(alpha = 0.06f), RoundedCornerShape(10.dp))
                .padding(14.dp),
        ) {
            SweepPreviewRow("Sent", formatSats(success.amount), PrimaryText)
            Spacer(Modifier.height(6.dp))
            SweepPreviewRow("Fee paid", formatSats(success.fee), SecondaryText)
        }
        Spacer(Modifier.height(20.dp))
        Text("Transaction ID", color = SecondaryText, fontSize = 12.sp)
        Spacer(Modifier.height(4.dp))
        Text(success.txid, color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
            textAlign = TextAlign.Center)
        Spacer(Modifier.height(16.dp))
        TextButton(onClick = { runCatching { uriHandler.openUri("https://mempool.btcforplebs.com/tx/${success.txid}") } }) {
            Text("View on mempool ↗", color = LocalNostrVaultColors.current.primary, fontWeight = FontWeight.Medium)
        }
    }
}

// ── Shared buttons ───────────────────────────────────────────────
@Composable
private fun SweepPrimaryButton(text: String, onClick: () -> Unit, enabled: Boolean = true) {
    Button(
        onClick = onClick,
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(containerColor = ZapOrange, disabledContainerColor = SecondaryText.copy(alpha = 0.3f)),
        modifier = Modifier.fillMaxWidth().height(50.dp),
    ) { Text(text, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center) }
}

@Composable
private fun SweepSecondaryButton(text: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(containerColor = SecondaryText.copy(alpha = 0.25f)),
        modifier = Modifier.fillMaxWidth().height(50.dp),
    ) { Text(text, fontWeight = FontWeight.SemiBold, color = PrimaryText) }
}
