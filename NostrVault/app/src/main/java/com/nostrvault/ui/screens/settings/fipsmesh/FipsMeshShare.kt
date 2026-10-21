package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.fips.FipsStatus
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.screens.settings.HavenRelaySettingsViewModel
import com.nostrvault.ui.screens.settings.MacSyncSection
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen

/** 4 Sync: the check against the Vault on Mac (the same one Sync with Vault on Mac runs) and the home vault's queue. */
@Composable
internal fun SyncSection(viewModel: FipsMeshViewModel, mac: HavenRelaySettingsViewModel = hiltViewModel()) {
    val macSync by mac.macSync.collectAsState()
    val checkRequested by mac.checkRequested.collectAsState()
    val pollNow by mac.pollNow.collectAsState()
    val relayReady by RelayForegroundService.readyForConnections.collectAsState()
    val home by viewModel.homeVaultState.collectAsState()
    val devices by viewModel.devices.collectAsState()
    val hasHome = devices.any { it.role == com.nostrvault.fips.DeviceRole.HOME_VAULT }
    val configuredMac = mac.configuredMac
    LaunchedEffect(Unit) { mac.pollMacSync() }

    MeshSection("Sync") {
        Spacer(Modifier.height(12.dp))
        if (configuredMac.isNotEmpty()) {
            MacSyncSection(MacSync.view(macSync, configuredMac, checkRequested, pollNow), checkRequested, relayReady, mac::checkSyncWithMac, showHeader = false)
        } else if (!hasHome) {
            Text("Nothing to sync yet. Set up Sync with Vault on Mac, or add a home vault under My Devices.", color = SecondaryText, fontSize = 13.sp)
        }
        if (hasHome) {
            if (configuredMac.isNotEmpty()) Spacer(Modifier.height(10.dp))
            Text(homeVaultLine(home), color = if (home.waiting > 0) SecondaryText else SuccessGreen, fontSize = 13.sp)
            if (home.waiting > 0 || home.publicPending > 0) TextButton(onClick = viewModel::sendHomeVaultNow) { Text("Send now", fontSize = 13.sp) }
        }
        Spacer(Modifier.height(12.dp))
    }
}

internal fun homeVaultLine(s: HomeVaultSender.State): String = when {
    s.waiting > 0 -> "Home vault: ${s.waiting} waiting until it's in reach" + (s.lastProblem?.let { " ($it)" } ?: "")
    s.publicPending > 0 -> "Home vault: ${s.publicPending} on the home vault only until a public server takes a copy"
    s.lastSentAt != null -> "Home vault: everything sent"
    else -> "Home vault: nothing to send yet"
}

/** 5 Share With Others: kiosk mode (this vault on the mesh), who can view, pause after, listing, and where photos go. */
@Composable
internal fun ShareSection(viewModel: FipsMeshViewModel, status: FipsStatus) {
    val shareRelay by viewModel.shareRelay.collectAsState()
    val serveLimit by viewModel.serveLimit.collectAsState()
    val settings by viewModel.settings.collectAsState()
    val busy by viewModel.busy.collectAsState()
    MeshSection(
        "Share With Others",
        footer = "Sharing pauses once the mesh has downloaded the amount above; one visitor gets at most 256 MB of it. " +
            "Listing links your account to this phone's mesh address in public, and turning it off later doesn't undo that.",
    ) {
        MeshSwitchRow("Kiosk mode", "Share this vault on the mesh", shareRelay, enabled = viewModel.isAvailable && !busy, onChange = viewModel::setShareRelay)
        MeshDivider()
        // The library takes the limit at start, so it is fixed while sharing.
        Picker("Pause after", serveLimit, SERVE_LIMITS.map { it to bytesLabel(it) }, enabled = !shareRelay && !busy) { viewModel.setServeLimit(it) }
        MeshDivider()
        MeshSwitchRow("List in my media servers", null, settings.listInMediaServers) { on -> viewModel.updateSettings { it.copy(listInMediaServers = on) } }
        MeshDivider()
        Picker("Photos go to", settings.photosGoTo, PHOTOS_GO_TO) { v -> viewModel.updateSettings { it.copy(photosGoTo = v) } }
        if (shareRelay && status.running) {
            MeshDivider()
            val c = status.counters
            StatusDot("Sharing · served ${c.servedTotal} ${if (c.servedTotal == 1L) "request" else "requests"}, ${bytesLabel(c.servedTx)}", true,
                Modifier.padding(vertical = 14.dp))
        }
    }
}

internal val PHOTOS_GO_TO = listOf(
    FipsMeshSettings.PHOTOS_PUBLIC to "Public server",
    FipsMeshSettings.PHOTOS_MAC to "My Mac",
    FipsMeshSettings.PHOTOS_BOTH to "Both",
)

/** A value row that opens a menu of [options], like the iPhone's menu picker. */
@Composable
internal fun <T> Picker(title: String, value: T, options: List<Pair<T, String>>, enabled: Boolean = true, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        MeshValueRow(title, options.firstOrNull { it.first == value }?.second ?: value.toString(), menu = enabled, onClick = if (enabled) ({ open = true }) else null)
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (v, label) -> DropdownMenuItem(text = { Text(label) }, onClick = { open = false; onPick(v) }) }
        }
    }
}
