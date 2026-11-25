package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.screens.settings.HavenRelaySettingsViewModel
import com.nostrvault.ui.screens.settings.MacSyncSection
import com.nostrvault.ui.screens.settings.SectionLabel
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor

/**
 * Settings › Desktop Vaults (Desktop Vaults P7, PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.7): every desktop Vault, in order,
 * with Add. Moving one sets the order of the Vault entries in the public lists (§2.5 rule 2): only the lists whose
 * Vault entries move are republished. Replaces the one-slot "Desktop vault sync" page. iOS twin:
 * `DesktopVaultsSettingsView.swift` (P4 #2511), whose drag is the arrows here.
 */
@Composable
fun DesktopVaultsScreen(
    onBack: () -> Unit,
    onOpenVault: (String) -> Unit,
    onPair: () -> Unit,
    viewModel: DesktopVaultsViewModel = hiltViewModel(),
    sync: HavenRelaySettingsViewModel = hiltViewModel(),
) {
    val vaults by viewModel.vaults.collectAsState()
    val orderLine by viewModel.orderLine.collectAsState()
    var showAdd by remember { mutableStateOf(false) }

    DesktopVaultPage("Desktop Vaults", onBack) {
        SectionLabel("Your desktop Vaults")
        if (vaults.isEmpty()) DesktopVaultNote(DesktopVaultText.EMPTY)
        vaults.forEachIndexed { i, vault ->
            if (i > 0) HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            DesktopVaultRow(
                vault, onOpen = { onOpenVault(vault.id) },
                onUp = if (i > 0) ({ viewModel.move(i, i - 1) }) else null,
                onDown = if (i < vaults.lastIndex) ({ viewModel.move(i, i + 1) }) else null,
            )
        }
        if (vaults.size > 1) DesktopVaultNote(orderLine ?: DesktopVaultText.ORDER_NOTE, warn = orderLine != null)

        DesktopVaultGap()
        AddRow(onClick = { showAdd = true })
        DesktopVaultNote(DesktopVaultText.ADD_NOTE)

        if (vaults.isNotEmpty()) {
            DesktopVaultGap()
            DesktopVaultSync(sync)
        }
    }
    if (showAdd) AddDesktopVaultSheet(viewModel, onPair = { showAdd = false; onPair() }, onDismiss = { showAdd = false })
}

/** One Vault in the list: its name, kind and how it is reached, with the order arrows. */
@Composable
private fun DesktopVaultRow(vault: DesktopVault, onOpen: () -> Unit, onUp: (() -> Unit)?, onDown: (() -> Unit)?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = 8.dp),
    ) {
        Icon(DesktopVaultText.icon(vault.kind), contentDescription = null, tint = DesktopVaultTeal, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(vault.displayName, color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(DesktopVaultText.paths(vault), color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (onUp != null || onDown != null) {
            IconButton(onClick = { onUp?.invoke() }, enabled = onUp != null) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "Move ${vault.displayName} up")
            }
            IconButton(onClick = { onDown?.invoke() }, enabled = onDown != null) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Move ${vault.displayName} down")
            }
        }
    }
}

@Composable
private fun AddRow(onClick: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
    ) {
        Icon(Icons.Filled.AddCircleOutline, contentDescription = null, tint = accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Text("Add a desktop Vault", color = accent, fontSize = 15.sp)
    }
}

/** The old page's Sync section: the relay's last copy and Check now (iOS `MacRelaySyncStatusView`). */
@Composable
private fun DesktopVaultSync(sync: HavenRelaySettingsViewModel) {
    val macSync by sync.macSync.collectAsState()
    val checkRequested by sync.checkRequested.collectAsState()
    val pollNow by sync.pollNow.collectAsState()
    val relayReady by RelayForegroundService.readyForConnections.collectAsState()
    LaunchedEffect(Unit) { sync.pollMacSync() }
    val configured = sync.configuredMac
    if (configured.isEmpty()) return
    MacSyncSection(MacSync.view(macSync, configured, checkRequested, pollNow), checkRequested, relayReady, sync::checkSyncWithMac)
}
