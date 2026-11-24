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
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
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
    @ApplicationContext private val context: Context,
) : ViewModel() {

    // ── Sync with Vault on Mac (iOS MacRelaySyncStatusView) ─────

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
}

/** The copy from the Mac and its missing-events check, with a re-run button. Also FIPS Mesh → Sync (no header). */
@Composable
internal fun MacSyncSection(
    view: MacSync.View,
    checkRequested: Boolean,
    relayReady: Boolean,
    onCheck: () -> Unit,
    showHeader: Boolean = true,
) {
    val colors = LocalNostrVaultColors.current
    Column(modifier = Modifier.fillMaxWidth()) {
        if (showHeader) Text(
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
            Text("Sync now", fontSize = 13.sp, fontWeight = FontWeight.Bold)
        }
    }
}
