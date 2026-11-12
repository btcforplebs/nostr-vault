package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCode2
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.fips.FipsStatus
import com.nostrvault.fips.MyDevice
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.screens.settings.YourDevicesRules.SyncAction
import com.nostrvault.ui.screens.settings.fipsmesh.FipsMeshViewModel
import com.nostrvault.ui.screens.settings.fipsmesh.MeshDivider
import com.nostrvault.ui.screens.settings.fipsmesh.MeshFooter
import com.nostrvault.ui.screens.settings.fipsmesh.MeshSection
import com.nostrvault.ui.screens.settings.fipsmesh.MeshSwitchRow
import com.nostrvault.ui.screens.settings.fipsmesh.MeshValueRow
import com.nostrvault.ui.screens.settings.fipsmesh.RoleTile
import com.nostrvault.ui.screens.settings.fipsmesh.SHARE_FOOTER
import com.nostrvault.ui.screens.settings.fipsmesh.StatusDot
import com.nostrvault.ui.screens.settings.fipsmesh.homeVaultLine
import com.nostrvault.ui.screens.settings.fipsmesh.pausedLine
import com.nostrvault.ui.screens.settings.fipsmesh.sharingLine
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WarningYellow
import com.nostrvault.ui.theme.WindowBackground
import kotlinx.coroutines.delay

/**
 * Settings › Your Devices: your devices with a Sync now on each vault, the two-scan link, this phone as an always-on
 * vault, and the Mesh and by-address pages under Advanced. Every control reuses an existing action: no new behaviour.
 * Twin of iOS `YourDevicesView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun YourDevicesScreen(
    onBack: () -> Unit,
    onOpenDevice: (String) -> Unit,
    /** The two-scan link (PairDeviceScreen). */
    onLinkDevice: () -> Unit,
    onOpenMesh: () -> Unit,
    onOpenDesktopByAddress: () -> Unit,
    viewModel: FipsMeshViewModel = hiltViewModel(),
    mac: HavenRelaySettingsViewModel = hiltViewModel(),
) {
    val status by viewModel.status.collectAsState()
    val devices by viewModel.devices.collectAsState()

    // As the Mesh screen: the bridge never calls back, so in reach is re-read while this screen is on top.
    LaunchedEffect(status.running) {
        while (status.running) {
            delay(2000)
            viewModel.refresh()
        }
    }
    LaunchedEffect(Unit) { mac.pollMacSync() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(YourDevicesRules.TITLE) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground, titleContentColor = PrimaryText, navigationIconContentColor = PrimaryText),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            DevicesSection(YourDevicesRules.ordered(devices), status.running, viewModel, mac, onOpenDevice)
            ConnectButton(
                onClick = {
                    // The same call as the Mesh switch; queued, so pairing's own start waits for it.
                    if (!status.running && viewModel.isAvailable) viewModel.setEnabled(true)
                    onLinkDevice()
                },
            )
            MeshFooter(YourDevicesRules.CONNECT_FOOTER)
            ThisPhoneSection(viewModel, status)
            MeshSection(YourDevicesRules.ADVANCED_HEADER) {
                MeshValueRow(YourDevicesRules.MESH_ROW, "", chevron = true, onClick = onOpenMesh)
                MeshDivider()
                MeshValueRow(YourDevicesRules.DESKTOP_BY_ADDRESS_ROW, "", chevron = true, onClick = onOpenDesktopByAddress)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun DevicesSection(
    devices: List<MyDevice>, running: Boolean, viewModel: FipsMeshViewModel, mac: HavenRelaySettingsViewModel, onOpen: (String) -> Unit,
) {
    val macSync by mac.macSync.collectAsState()
    val checkRequested by mac.checkRequested.collectAsState()
    val pollNow by mac.pollNow.collectAsState()
    val relayReady by RelayForegroundService.readyForConnections.collectAsState()
    val home by viewModel.homeVaultState.collectAsState()
    val configuredMac = mac.configuredMac
    val macView = MacSync.view(macSync, configuredMac, checkRequested, pollNow)
    val now = System.currentTimeMillis() / 1000

    MeshSection(YourDevicesRules.DEVICES_HEADER) {
        if (devices.isEmpty()) {
            Text(YourDevicesRules.NO_DEVICES, color = SecondaryText, fontSize = 15.sp, modifier = Modifier.padding(vertical = 14.dp))
        }
        devices.forEachIndexed { i, d ->
            if (i > 0) MeshDivider()
            val action = YourDevicesRules.syncAction(d.role)
            DeviceCard(
                device = d,
                status = MyDevicesRules.rowText(d.inReach, d.lastSeen, now),
                on = d.inReach && running,
                detail = when (action) {
                    SyncAction.DESKTOP_SYNC_CHECK -> macView.headline.takeIf { configuredMac.isNotEmpty() }
                    SyncAction.MOBILE_VAULT_SEND -> homeVaultLine(home)
                    null -> null
                },
                syncEnabled = when (action) {
                    SyncAction.DESKTOP_SYNC_CHECK ->
                        YourDevicesRules.desktopSyncEnabled(configuredMac, macView.running, checkRequested, relayReady)
                    SyncAction.MOBILE_VAULT_SEND -> YourDevicesRules.mobileSendEnabled(home)
                    null -> false
                },
                onSync = when (action) {
                    SyncAction.DESKTOP_SYNC_CHECK -> mac::checkSyncWithMac
                    SyncAction.MOBILE_VAULT_SEND -> viewModel::sendHomeVaultNow
                    null -> null
                },
                onOpen = { onOpen(d.npub) },
            )
        }
    }
}

/** One device: tile, name, role, in reach or last seen, and Sync now on the two vaults. Opens the device page. */
@Composable
private fun DeviceCard(
    device: MyDevice, status: String, on: Boolean, detail: String?, syncEnabled: Boolean, onSync: (() -> Unit)?, onOpen: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = 12.dp)) {
        RoleTile(device.role)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(device.title, color = PrimaryText, fontSize = 16.sp, maxLines = 1)
            Text(device.role.label, color = SecondaryText, fontSize = 13.sp)
            StatusDot(status, on)
            detail?.let { Text(it, color = SecondaryText, fontSize = 12.sp, lineHeight = 16.sp) }
        }
        if (onSync != null) {
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = onSync,
                enabled = syncEnabled,
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            ) { Text(YourDevicesRules.SYNC_NOW, fontSize = 13.sp) }
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun ConnectButton(onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(containerColor = colors.primary.copy(alpha = 0.25f), contentColor = colors.primary),
        modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
    ) {
        Icon(Icons.Filled.QrCode2, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(YourDevicesRules.CONNECT)
    }
}

/**
 * This phone: the Mobile vault mode switch from Mesh › Share With Others, bound to the same state
 * (FipsMeshViewModel.shareRelay / setShareRelay), with the same sharing and paused lines.
 */
@Composable
private fun ThisPhoneSection(viewModel: FipsMeshViewModel, status: FipsStatus) {
    val shareRelay by viewModel.shareRelay.collectAsState()
    val pausedUntil by viewModel.pausedUntil.collectAsState()
    MeshSection(YourDevicesRules.THIS_PHONE_HEADER, footer = SHARE_FOOTER) {
        MeshSwitchRow(YourDevicesRules.ALWAYS_ON_VAULT, null, shareRelay, enabled = viewModel.isAvailable, onChange = viewModel::setShareRelay)
        if (shareRelay && status.running) {
            MeshDivider()
            val until = pausedUntil
            StatusDot(sharingLine(status, until != null), true, Modifier.padding(vertical = 14.dp), warning = until != null)
            if (until != null) {
                Text(pausedLine(until), color = WarningYellow, fontSize = 13.sp, modifier = Modifier.padding(bottom = 14.dp))
            }
        }
    }
    if (!viewModel.isAvailable) {
        MeshFooter("This build does not include the mesh library for your device's processor, so the mesh cannot be turned on here.", ErrorRed)
    }
}
