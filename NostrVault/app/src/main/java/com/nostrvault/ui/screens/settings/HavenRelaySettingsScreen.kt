package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.MacSyncStatus
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.File
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HavenRelaySettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: com.nostrvault.service.NostrService,
    @ApplicationContext private val context: Context,
) : ViewModel() {

    // ── Sync with Mac (iOS MacRelaySyncStatusView) ──────────────

    private val _macSync = MutableStateFlow<MacSyncStatus?>(null)
    val macSync = _macSync.asStateFlow()

    /** Poll time in seconds, so a copy whose heartbeat stops reads as interrupted. */
    private val _pollNow = MutableStateFlow(System.currentTimeMillis() / 1000)
    val pollNow = _pollNow.asStateFlow()

    private val _checkRequested = MutableStateFlow(false)
    val checkRequested = _checkRequested.asStateFlow()

    private var checkRequestedAt = 0L
    private var statusAtRequest: MacSyncStatus? = null

    /** The Mac address the relay runs with (MAC_RELAY_URL) for the saved config. */
    val configuredMac: String get() = MacSync.macRelayURL(configStore.config.value)

    /** The saved config, for the "Also Used For" addresses. */
    val config = configStore.config

    /** Polls the relay's status file every 2s while the screen shows. */
    suspend fun pollMacSync() {
        val relayDir = File(context.filesDir, "relay_data")
        while (kotlin.coroutines.coroutineContext.isActive) {
            val latest = withContext(Dispatchers.IO) { MacSync.read(relayDir) }
            if (_checkRequested.value) {
                // Never spin forever: a request the relay didn't take clears itself.
                if (MacSync.pickedUp(latest, statusAtRequest) || System.currentTimeMillis() - checkRequestedAt > 30_000) {
                    _checkRequested.value = false
                }
            }
            _macSync.value = latest
            _pollNow.value = System.currentTimeMillis() / 1000
            delay(2_000)
        }
    }

    fun checkSyncWithMac() {
        if (!HavenBridge.isLoaded) return
        statusAtRequest = _macSync.value
        checkRequestedAt = System.currentTimeMillis()
        _checkRequested.value = true
        HavenBridge.requestMacSyncCheck()
    }

    private val _urlInput = MutableStateFlow("")
    val urlInput = _urlInput.asStateFlow()

    private val _saved = MutableStateFlow(false)
    val saved = _saved.asStateFlow()

    init {
        _urlInput.value = configStore.config.value.macRelayURL
    }

    fun setUrlInput(value: String) {
        _urlInput.value = value
        _saved.value = false
    }

    fun save() {
        viewModelScope.launch {
            val before = configStore.config.value
            val oldInbox = before.ownHavenDMInboxURL
            configStore.update { cfg ->
                val updated = cfg.copy(macRelayURL = _urlInput.value.trim())
                // An adopted DM list may carry the old Haven inbox; drop it so
                // senders and every device move to the new address.
                if (oldInbox.isNotEmpty() && oldInbox != updated.ownHavenDMInboxURL) {
                    updated.copy(dmRelays = updated.dmRelays.filter { !it.trim().trimEnd('/').equals(oldInbox, ignoreCase = true) })
                } else updated
            }
            // The DM inbox list leads with the Haven inbox: publish when it moved.
            if (configStore.config.value.ownHavenDMInboxURL != oldInbox) {
                nostrService.publishOwnerDMInboxList()
            }
            _saved.value = true
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HavenRelaySettingsScreen(
    onBack: () -> Unit,
    viewModel: HavenRelaySettingsViewModel = hiltViewModel(),
) {
    val urlInput by viewModel.urlInput.collectAsState()
    val saved by viewModel.saved.collectAsState()
    val macSync by viewModel.macSync.collectAsState()
    val checkRequested by viewModel.checkRequested.collectAsState()
    val pollNow by viewModel.pollNow.collectAsState()
    val relayReady by RelayForegroundService.readyForConnections.collectAsState()
    val colors = LocalNostrVaultColors.current
    LaunchedEffect(Unit) { viewModel.pollMacSync() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Haven Relay") },
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
                // Scrolls: with a relay saved, Also Used For and Sync don't fit.
                .verticalScroll(androidx.compose.foundation.rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(16.dp))

            Text(
                text = "SYNC RELAY",
                color = SecondaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.sp,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            OutlinedTextField(
                value = urlInput,
                onValueChange = viewModel::setUrlInput,
                placeholder = { Text("wss://relay.yourdomain.com") },
                label = { Text("Haven Relay URL") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    focusedLabelColor = colors.primary,
                    cursorColor = colors.primary,
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(8.dp))

            Text(
                text = "Your Mac, Linux, or cloud-hosted Haven relay. When set, the app syncs your notes from this relay so posts made on other devices appear here.",
                color = SecondaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = viewModel::save,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            ) {
                Text("Save", color = PrimaryText, fontWeight = FontWeight.SemiBold)
            }

            if (saved) {
                Spacer(Modifier.height(12.dp))
                Surface(
                    color = SuccessGreen.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                    ) {
                        Icon(
                            NostrVaultIcons.Check,
                            contentDescription = null,
                            tint = SuccessGreen,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("Saved", color = SuccessGreen, fontSize = 14.sp)
                    }
                }
            }

            // What the saved relay is also used for (iOS MacRelaySettingsView
            // "Also Used For"). The app adds it to these lists when it reads them.
            val savedConfig by viewModel.config.collectAsState()
            val wss = savedConfig.macRelayWssURL
            if (wss.isNotEmpty()) {
                Spacer(Modifier.height(24.dp))
                AlsoUsedForSection(
                    listOf(
                        "Feed Relays" to wss,
                        "Import Relays" to wss,
                        "Blastr Relays" to wss,
                        "Blossom Mirror" to savedConfig.macRelayHttpsURL,
                    ),
                )
            }

            val configuredMac = viewModel.configuredMac
            if (configuredMac.isNotEmpty()) {
                Spacer(Modifier.height(24.dp))
                MacSyncSection(
                    view = MacSync.view(macSync, configuredMac, checkRequested, pollNow),
                    checkRequested = checkRequested,
                    relayReady = relayReady,
                    onCheck = viewModel::checkSyncWithMac,
                )
            }
        }
    }
}

/** Read-only: each list that also uses the Haven relay, and the address it uses there. */
@Composable
private fun AlsoUsedForSection(rows: List<Pair<String, String>>) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "ALSO USED FOR",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(bottom = 8.dp),
        )
        Surface(shape = RoundedCornerShape(10.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) {
                for ((title, address) in rows) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                        Icon(NostrVaultIcons.Check, contentDescription = null, tint = SuccessGreen, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(title, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                            Text(
                                address, color = SecondaryText, fontSize = 12.sp,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** The copy from the Mac and its missing-events check, with a re-run button. */
@Composable
private fun MacSyncSection(
    view: MacSync.View,
    checkRequested: Boolean,
    relayReady: Boolean,
    onCheck: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "SYNC",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(bottom = 8.dp),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (view.running || checkRequested) {
                CircularProgressIndicator(
                    color = colors.primary,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(16.dp),
                )
            } else {
                val (icon, tint) = when (view.outcome) {
                    "done" -> NostrVaultIcons.Check to SuccessGreen
                    "incomplete" -> NostrVaultIcons.Alert to ZapOrange
                    "failed" -> NostrVaultIcons.Alert to ErrorRed
                    else -> NostrVaultIcons.History to SecondaryText
                }
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            }
            Spacer(Modifier.width(8.dp))
            Text(view.headline, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        view.detail?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, color = SecondaryText, fontSize = 12.sp, lineHeight = 16.sp)
        }
        Spacer(Modifier.height(10.dp))
        Button(
            onClick = onCheck,
            enabled = !view.running && !checkRequested && relayReady,
            shape = RoundedCornerShape(10.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        ) {
            Icon(NostrVaultIcons.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("Check sync with Mac", fontSize = 13.sp, fontWeight = FontWeight.Bold)
        }
    }
}
