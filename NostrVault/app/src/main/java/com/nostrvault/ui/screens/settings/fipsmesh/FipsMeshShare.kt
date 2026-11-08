package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.fips.FipsStatus
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.screens.settings.HavenRelaySettingsViewModel
import com.nostrvault.ui.screens.settings.MacSyncSection
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.WarningYellow

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
            Text("Add a mobile vault under My Devices to sync with it.", color = SecondaryText, fontSize = 13.sp)
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
    s.waiting > 0 -> "Mobile vault: ${s.waiting} waiting until it's in reach" + (s.lastProblem?.let { " ($it)" } ?: "")
    s.publicPending > 0 -> "Mobile vault: ${s.publicPending} on the mobile vault only until a media server takes a copy"
    s.lastSentAt != null -> "Mobile vault: everything sent"
    else -> "Mobile vault: nothing to send yet"
}

/** 5 Share With Others: kiosk mode (this vault on the mesh), where new photos are saved, and the sharing status. */
@Composable
internal fun ShareSection(viewModel: FipsMeshViewModel, status: FipsStatus) {
    val shareRelay by viewModel.shareRelay.collectAsState()
    val pausedUntil by viewModel.pausedUntil.collectAsState()
    MeshSection("Share With Others", footer = SHARE_FOOTER) {
        MeshSwitchRow("Mobile vault mode", "Share this vault on the mesh while the app stays open", shareRelay, enabled = viewModel.isAvailable, onChange = viewModel::setShareRelay)
        MeshDivider()
        Text(PHOTOS_ROUTE_LINE, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(vertical = 14.dp))
        if (shareRelay && status.running) {
            MeshDivider()
            val until = pausedUntil
            StatusDot(sharingLine(status, until != null), true, Modifier.padding(vertical = 14.dp), warning = until != null)
            if (until != null) {
                Text(pausedLine(until), color = WarningYellow, fontSize = 13.sp, modifier = Modifier.padding(bottom = 14.dp))
            }
        }
    }
}

/** No "Pause after" (iPhone #1023): own devices are never capped, everyone else gets fixed caps a day. */
internal const val SHARE_FOOTER = "The devices in My Devices reach this vault in full. Anyone else on the mesh can read only " +
    "the photos in your posts: at most 1 GB a day for all of them together (then they wait until the next day), and 256 MB each."

/** "Sharing · served 3 requests, 12 MB", or "Sharing paused" while others wait (iOS FipsMeshShareSection). */
internal fun sharingLine(status: FipsStatus, paused: Boolean): String {
    if (paused) return "Sharing paused"
    val n = status.servedRequests
    return "Sharing · served $n ${if (n == 1L) "request" else "requests"}, ${bytesLabel(status.servedBytes)}"
}

/** The orange line under a paused share (iOS FipsMeshShareSection), with the time others can read again. */
internal fun pausedLine(untilMs: Long, zone: java.time.ZoneId = java.time.ZoneId.systemDefault(), locale: java.util.Locale = java.util.Locale.getDefault()): String {
    val at = java.time.Instant.ofEpochMilli(untilMs).atZone(zone)
    val text = java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.MEDIUM, java.time.format.FormatStyle.SHORT).withLocale(locale).format(at)
    return "Paused for others: the mesh downloaded today's limit. Your own devices still reach this vault. Others can read again $text."
}

/**
 * Where a new photo goes, said once instead of a "Photos go to" picker (Logen 2026-11-05):
 * nothing read the picker's value, and the route is fixed, so it offered a choice that did nothing.
 */
internal const val PHOTOS_ROUTE_LINE = "New photos are saved on this device first. If you have a mobile vault, a copy goes to it " +
    "over the mesh, and the mobile vault puts it on your public media server for you. If this device has its own media " +
    "server, it uploads there itself."
