package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.MyDevice
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

/**
 * Vault Dashboard › Your devices (plan §6): your linked devices with the green dot for the ones in reach, and Add a
 * device, which opens the two-scan link. A device and the Mesh settings row open the Mesh settings screen (Logen
 * 2026-11-06); Advanced keeps its link too. Twin of iOS `YourDevicesSection.swift`.
 */
@Composable
internal fun YourDevicesCard(
    onAddDevice: () -> Unit,
    onOpenDevice: () -> Unit,
    onOpenMesh: () -> Unit,
    viewModel: YourDevicesViewModel = hiltViewModel(),
) {
    val devices by viewModel.devices.collectAsState()
    // In reach changes as the mesh meets them: re-read while the card is up.
    LaunchedEffect(Unit) {
        while (true) {
            viewModel.refresh()
            delay(REFRESH_MS)
        }
    }
    DashSection(
        title = "Your devices",
        detail = if (devices.isEmpty()) null else "${devices.count { it.inReach }} of ${devices.size} in reach",
    ) {
        devices.forEachIndexed { i, device ->
            if (i > 0) DashDivider()
            DeviceRow(device, onClick = onOpenDevice)
        }
        if (devices.isNotEmpty()) DashDivider()
        SettingLink(Icons.Filled.Hub, "Mesh settings", null, onClick = onOpenMesh)
        DashDivider()
        DashRow(
            icon = Icons.Filled.Devices,
            title = if (devices.isEmpty()) "Link your other devices" else "Add a device",
            detail = "Two scans: one on each device.",
            state = RowState.INFO,
        ) {
            RowButton(title = "Add", onClick = onAddDevice)
        }
    }
}

@Composable
private fun DeviceRow(device: MyDevice, onClick: () -> Unit) {
    val reach = if (device.inReach) "In reach" else "Not in reach"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = "${device.title}, ${device.role.label}, $reach" }
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(10.dp).background(if (device.inReach) SuccessGreen else SecondaryText.copy(alpha = 0.5f), CircleShape))
        }
        Column(Modifier.weight(1f)) {
            Text(device.title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(device.role.label, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

private const val REFRESH_MS = 5_000L

@HiltViewModel
class YourDevicesViewModel @Inject constructor(
    private val mesh: FipsMeshManager,
    configStore: ConfigStore,
) : ViewModel() {
    val devices = combine(configStore.config, mesh.status) { cfg, st ->
        MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, st.peers, cfg.ownerNpub)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    suspend fun refresh() = mesh.refresh()
}
