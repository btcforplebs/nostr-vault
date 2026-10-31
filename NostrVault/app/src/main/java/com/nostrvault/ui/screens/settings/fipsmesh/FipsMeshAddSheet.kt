package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.HomeVaultRules
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.ui.theme.CardBackground
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/** "Add a device by address": scan or paste its mesh address, then say what it is (06_add.png). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AddDeviceSheet(viewModel: FipsMeshViewModel, onDismiss: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val suggestions by viewModel.suggestions.collectAsState()
    val status by viewModel.status.collectAsState()
    var address by rememberSaveable { mutableStateOf("") }
    var role by rememberSaveable { mutableStateOf(DeviceRole.MAC) }
    var name by rememberSaveable { mutableStateOf("") }
    // A mesh address whose checksum holds: a one-character typo would be a dead entry in the allowlist.
    val npub = remember(address) { HomeVaultRules.meshNpubFromInput(address)?.takeIf(MyDevicesRules::isMeshNpub) }
    val isSelf = npub != null && npub == status.npub
    val scanner = rememberLauncherForActivityResult(ScanContract()) { r -> r.contents?.trim()?.let { address = it } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = CardBackground) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).navigationBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Text("Add a Device", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f).padding(start = 8.dp))
                TextButton(
                    onClick = { if (npub != null && viewModel.addDevice(npub, role, name)) onDismiss() },
                    enabled = npub != null && !isSelf,
                ) { Text("Add", fontWeight = FontWeight.SemiBold) }
            }

            MeshSection("Address", footer = "Open Mesh on the other device and copy the address under This Device.") {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable {
                    scanner.launch(ScanOptions().apply {
                        setDesiredBarcodeFormats(ScanOptions.QR_CODE); setPrompt("Scan the other device's mesh address")
                        setBeepEnabled(false); setOrientationLocked(true)
                    })
                }.padding(vertical = 14.dp)) {
                    Icon(Icons.Filled.QrCodeScanner, contentDescription = null, tint = colors.primary, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(12.dp))
                    Text("Scan its QR code", color = colors.primary, fontSize = 16.sp)
                }
                MeshDivider()
                OutlinedTextField(
                    value = address, onValueChange = { address = it }, singleLine = true,
                    placeholder = { Text("npub1… mesh address", fontSize = 13.sp, fontFamily = FontFamily.Monospace) },
                    isError = address.isNotBlank() && (npub == null || isSelf),
                    textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                )
            }
            if (address.isNotBlank() && npub == null) MeshFooter("That isn't a mesh address. Check it for a typo, or copy it again.", ErrorRed)
            if (isSelf) MeshFooter("That is this phone's own address.", ErrorRed)
            if (suggestions.isNotEmpty() && address.isBlank()) {
                MeshSection("In Your Media Servers", footer = "Home vaults your account lists. Tap one to use its address.") {
                    suggestions.forEach { s ->
                        Text(s.take(16) + "…" + s.takeLast(8), color = PrimaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace,
                            modifier = Modifier.fillMaxWidth().clickable { address = s; role = DeviceRole.HOME_VAULT }.padding(vertical = 12.dp))
                    }
                }
            }

            MeshSection("This Is", footer = role.blurb) {
                DeviceRole.entries.forEachIndexed { i, r ->
                    if (i > 0) MeshDivider()
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable { role = r }.padding(vertical = 12.dp)) {
                        Icon(r.icon, contentDescription = null, tint = colors.primary, modifier = Modifier.size(24.dp))
                        Spacer(Modifier.width(12.dp))
                        Text(r.label, color = PrimaryText, fontSize = 16.sp, modifier = Modifier.weight(1f))
                        if (r == role) Icon(Icons.Filled.Check, contentDescription = "Selected", tint = colors.primary)
                    }
                }
            }
            if (role == DeviceRole.HOME_VAULT) {
                MeshFooter("A home vault's mesh address is listed in your media servers, in public. It must let your account write to its relay. " +
                    "Direct-message attachments are never sent there.", SecondaryText)
            }
            OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, placeholder = { Text("Name (optional)") },
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp))
            Spacer(Modifier.height(24.dp))
        }
    }
}
