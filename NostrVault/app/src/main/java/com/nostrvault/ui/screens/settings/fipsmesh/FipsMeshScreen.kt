package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.filled.AddCircle
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.nostrvault.fips.FipsStatus
import com.nostrvault.fips.MyDevice
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground
import kotlinx.coroutines.delay

/**
 * Settings → Mesh → FIPS Mesh: the one place for the mesh, in the iPhone's six sections and labels
 * (RESEARCH/NV_FIPS_SETTINGS_DESIGN.md): Mesh, This Device, My Devices, Sync, Share With Others, Advanced.
 * Replaces Android's old Mesh screen; its Who Can Reach You and Home Vault are now the one My Devices list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FipsMeshScreen(
    onBack: () -> Unit,
    onOpenDevice: (String) -> Unit,
    onOpenAdvanced: () -> Unit,
    viewModel: FipsMeshViewModel = hiltViewModel(),
) {
    val status by viewModel.status.collectAsState()
    val lastError by viewModel.lastError.collectAsState()
    val devices by viewModel.devices.collectAsState()
    var adding by rememberSaveable { mutableStateOf(false) }

    // Polled, not pushed: the bridge never calls back into the JVM, so state is read while this screen is on top.
    LaunchedEffect(status.running) {
        while (status.running) {
            delay(2000)
            viewModel.refresh()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Mesh") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground, titleContentColor = PrimaryText, navigationIconContentColor = PrimaryText),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            if (!viewModel.isAvailable) {
                MeshFooter("This build does not include the mesh library for your device's processor, so the mesh cannot be turned on here.", ErrorRed)
            }
            MeshSection(
                title = null,
                footer = if (status.running) "Your devices reach each other over the mesh, with no public IP or domain."
                else "Turn the mesh on to reach your home vault, your other phones and your browser vault from this phone.",
            ) {
                MeshSwitchRow(
                    "Mesh", null, status.running, enabled = viewModel.isAvailable,
                    below = { StatusDot(MyDevicesRules.statusLine(status.running, devices), status.running, Modifier.padding(top = 2.dp)) },
                    onChange = viewModel::setEnabled,
                )
            }
            lastError?.let { MeshFooter(it, ErrorRed) }

            // Only This Device needs the mesh running (its address comes from the engine). My Devices and Share With
            // Others stay usable when it is off: taking a lost phone out, or turning kiosk mode off, must never need
            // the mesh on first, which would announce this phone and let that phone dial in (Tron, #981).
            if (status.running) ThisDeviceSection(status)
            MyDevicesSection(devices, status.running, onOpenDevice) { adding = true }
            SyncSection(viewModel)
            ShareSection(viewModel, status)
            MeshSection(title = null) {
                MeshValueRow("Advanced", "Finder relays, middle server", chevron = true, onClick = onOpenAdvanced)
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (adding) AddDeviceSheet(viewModel, onDismiss = { adding = false })
}

@Composable
private fun ThisDeviceSection(status: FipsStatus) {
    val clipboard = LocalClipboardManager.current
    val colors = LocalNostrVaultColors.current
    var showQr by remember { mutableStateOf(false) }
    val npub = status.npub ?: return
    MeshSection("This Device", footer = "Add this address on your other devices so they let this phone in.") {
        Text("Mesh address", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp))
        Text(npub, color = PrimaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace, lineHeight = 18.sp, modifier = Modifier.padding(top = 4.dp, bottom = 12.dp))
        status.address?.let {
            MeshDivider()
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp)) {
                Text("Mesh IP", color = PrimaryText, fontSize = 16.sp, modifier = Modifier.weight(1f))
                Text(it, color = SecondaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
        }
        MeshDivider()
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
            val tinted = ButtonDefaults.buttonColors(containerColor = colors.primary.copy(alpha = 0.25f), contentColor = colors.primary)
            Button(onClick = { clipboard.setText(AnnotatedString(npub)) }, colors = tinted, modifier = Modifier.weight(1f)) {
                Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Copy")
            }
            Button(onClick = { showQr = !showQr }, colors = tinted, modifier = Modifier.weight(1f)) {
                Icon(Icons.Filled.QrCode2, contentDescription = null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(if (showQr) "Hide QR" else "Show QR")
            }
        }
        if (showQr) {
            // What the other device scans under Add a device by address.
            val qr = remember(npub) { runCatching { BarcodeEncoder().encodeBitmap("fipsmesh://$npub/", BarcodeFormat.QR_CODE, 480, 480) }.getOrNull() }
            qr?.let {
                Box(Modifier.fillMaxWidth().padding(bottom = 14.dp), contentAlignment = Alignment.Center) {
                    Image(it.asImageBitmap(), contentDescription = "Mesh address QR code",
                        modifier = Modifier.size(200.dp).background(Color.White, RoundedCornerShape(8.dp)).padding(8.dp))
                }
            }
        }
    }
}

@Composable
private fun MyDevicesSection(devices: List<MyDevice>, running: Boolean, onOpen: (String) -> Unit, onAdd: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val now = System.currentTimeMillis() / 1000
    // The address is hidden only once a device is listed (MeshEnginePlan): say so while none is (Tron, #1025).
    val footer = if (devices.isEmpty()) {
        "Your home vaults, phones and browser vault, in one list. Until you add one, anyone on the mesh can learn this phone's address."
    } else {
        "Your home vaults, phones and browser vault, in one list. Only the addresses here can reach this phone's vault or learn its address."
    }
    MeshSection("My Devices", footer = footer) {
        devices.forEach { d ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable { onOpen(d.npub) }.padding(vertical = 12.dp)) {
                RoleTile(d.role)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(d.title, color = PrimaryText, fontSize = 16.sp, maxLines = 1)
                    Text(d.role.label, color = SecondaryText, fontSize = 13.sp)
                }
                StatusDot(if (d.inReach) "In reach" else MyDevicesRules.lastSeenText(d.lastSeen, false, now), d.inReach && running)
                Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(20.dp))
            }
            MeshDivider()
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable(onClick = onAdd).padding(vertical = 14.dp)) {
            Icon(Icons.Filled.AddCircle, contentDescription = null, tint = colors.primary, modifier = Modifier.size(26.dp))
            Spacer(Modifier.width(12.dp))
            Text("Add a device by address", color = colors.primary, fontSize = 16.sp)
        }
    }
}
