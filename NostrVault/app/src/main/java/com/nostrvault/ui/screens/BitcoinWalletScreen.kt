package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.NostrService
import com.nostrvault.ui.screens.settings.InfoButton
import com.nostrvault.ui.screens.settings.SettingsHelp
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject

/**
 * The on-chain wallet: the taproot address derived from the Nostr key and its
 * sweep. Reached only from Settings > Advanced; the Wallet screen is
 * Lightning only (Logen, 2026-10-20).
 */
@HiltViewModel
class BitcoinWalletViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config

    private val _taprootAddress = MutableStateFlow<String?>(null)
    val taprootAddress = _taprootAddress.asStateFlow()

    init {
        if (config.value.showBitcoinWallet) deriveAddress()
    }

    fun toggleBitcoin(on: Boolean) {
        configStore.update { it.copy(showBitcoinWallet = on) }
        if (on) deriveAddress() else _taprootAddress.value = null
    }

    private fun deriveAddress() {
        val hex = nostrService.ownerHexPubkey
        if (hex.isNotEmpty()) _taprootAddress.value = HavenBridge.deriveTaprootAddress(hex)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BitcoinWalletScreen(
    onBack: () -> Unit,
    onSweep: () -> Unit,
    viewModel: BitcoinWalletViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val taproot by viewModel.taprootAddress.collectAsState()
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Bitcoin On-Chain") },
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Bitcoin Address", color = PrimaryText, fontSize = 15.sp)
                        InfoButton(SettingsHelp.WALLET_BITCOIN)
                    }
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
        }
    }
}
