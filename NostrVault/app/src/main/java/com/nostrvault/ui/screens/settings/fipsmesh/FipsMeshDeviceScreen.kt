package com.nostrvault.ui.screens.settings.fipsmesh

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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

/** One of My Devices: its address, what it gets, Remove (07_device.png). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FipsMeshDeviceScreen(npub: String, onBack: () -> Unit, viewModel: FipsMeshViewModel = hiltViewModel()) {
    val devices by viewModel.devices.collectAsState()
    val status by viewModel.status.collectAsState()
    val device = devices.firstOrNull { it.npub == npub }
    val clipboard = LocalClipboardManager.current
    val colors = LocalNostrVaultColors.current
    // Leaving once: Remove goes back itself, so the "it is gone" effect below must not pop a second screen.
    var leaving by remember { mutableStateOf(false) }
    val leave = { if (!leaving) { leaving = true; onBack() } }
    // Gone (removed elsewhere): back to the list.
    LaunchedEffect(device == null) { if (device == null && devices.isNotEmpty()) leave() }
    var name by rememberSaveable(npub) { mutableStateOf(device?.name.orEmpty()) }
    // The list can arrive a moment after the page: take the saved name then, unless something was typed.
    var nameLoaded by rememberSaveable(npub) { mutableStateOf(device != null) }
    LaunchedEffect(device != null) { if (device != null && !nameLoaded) { name = device.name; nameLoaded = true } }
    // The name is kept however the page is left: back arrow, system back or Remove (then there is nothing to keep).
    val latestName by rememberUpdatedState(name)
    val latestNameLoaded by rememberUpdatedState(nameLoaded)
    DisposableEffect(npub) {
        onDispose {
            val saved = viewModel.devices.value.firstOrNull { it.npub == npub }
            if (saved != null && latestNameLoaded && latestName.trim() != saved.name) viewModel.updateDevice(npub) { it.copy(name = latestName.trim()) }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(device?.title ?: "Device", maxLines = 1) },
                navigationIcon = { IconButton(onClick = { leave() }) { Icon(NostrVaultIcons.Back, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground, titleContentColor = PrimaryText, navigationIconContentColor = PrimaryText),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        val d = device ?: return@Scaffold
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            MeshSection(null) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
                    RoleTile(d.role)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(d.title, color = PrimaryText, fontSize = 16.sp, maxLines = 1)
                        Text(d.role.label, color = SecondaryText, fontSize = 13.sp)
                    }
                    StatusDot(if (d.inReach) "In reach" else "Not in reach", d.inReach && status.running)
                }
                MeshDivider()
                Text(d.role.blurb, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(vertical = 12.dp))
            }
            OutlinedTextField(value = name, onValueChange = { name = it; nameLoaded = true }, singleLine = true, label = { Text("Name") },
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp))

            MeshSection("Mesh Address") {
                Text(d.npub, color = PrimaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace, lineHeight = 18.sp, modifier = Modifier.padding(vertical = 12.dp))
                MeshDivider()
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable { clipboard.setText(AnnotatedString(d.npub)) }.padding(vertical = 14.dp)) {
                    Icon(NostrVaultIcons.Copy, contentDescription = null, tint = colors.primary, modifier = Modifier.size(22.dp))
                    Spacer(Modifier.width(12.dp))
                    Text("Copy address", color = colors.primary, fontSize = 16.sp)
                }
            }

            MeshSection("What It Gets") {
                MeshSwitchRow("Send new notes", null, d.sendNotes) { on -> viewModel.updateDevice(npub) { it.copy(sendNotes = on) } }
                MeshDivider()
                MeshSwitchRow("Send new media", null, d.sendMedia) { on -> viewModel.updateDevice(npub) { it.copy(sendMedia = on) } }
                MeshDivider()
                MeshValueRow("Last seen", MyDevicesRules.lastSeenText(d.lastSeen, d.inReach && status.running, System.currentTimeMillis() / 1000))
            }

            MeshSection(null, footer = "It can no longer reach this phone's vault. Anything it already has stays on it.") {
                Text("Remove from My Devices", color = ErrorRed, fontSize = 16.sp,
                    modifier = Modifier.fillMaxWidth().clickable { viewModel.removeDevice(npub); leave() }.padding(vertical = 14.dp))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
