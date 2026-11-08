package com.nostrvault.ui.screens.settings.fipsmesh

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.WindowBackground

/** FIPS Mesh → Advanced: finder relays and the middle server (08_advanced.png). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FipsMeshAdvancedScreen(onBack: () -> Unit, viewModel: FipsMeshViewModel = hiltViewModel()) {
    val settings by viewModel.settings.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val colors = LocalNostrVaultColors.current
    var draft by rememberSaveable { mutableStateOf("") }
    // What the engine runs with: the user's list, or the three every Nostr Vault starts with.
    val relays = settings.engineFinderRelays

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Advanced") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground, titleContentColor = PrimaryText, navigationIconContentColor = PrimaryText),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            // The by-address path (Add a device, then Paste instead, on another device): copy this phone's mesh address. The
            // two-scan Link a device on Mesh settings is the way for your own devices (Logen 2026-11-05).
            val status by viewModel.status.collectAsState()
            status.npub?.let { npub ->
                MeshSection("Mesh Address", footer = "For a device that can't scan, such as a Linux box: add this address there. Your phones, iPads and Macs link with Link a device instead.") {
                    Text(npub, color = PrimaryText, fontSize = 13.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        lineHeight = 18.sp, modifier = Modifier.padding(top = 12.dp))
                    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
                    TextButton(onClick = { clipboard.setText(androidx.compose.ui.text.AnnotatedString(npub)) }) {
                        Icon(NostrVaultIcons.Copy, contentDescription = null); Spacer(Modifier.width(6.dp)); Text("Copy")
                    }
                }
            }
            MeshSection(
                "Finder Relays",
                footer = "Your devices post where they are here, so the others can find them. They see this phone's IP address the way any relay does. One must stay.",
            ) {
                relays.forEach { r ->
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Text(r, color = PrimaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f).padding(vertical = 14.dp))
                        // The last one stays: with none, devices could not find each other.
                        TextButton(onClick = { viewModel.setFinderRelays(relays - r) }, enabled = !busy && relays.size > 1) { Text("Remove", fontSize = 13.sp) }
                    }
                    MeshDivider()
                }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    OutlinedTextField(
                        value = draft, onValueChange = { draft = it }, singleLine = true,
                        placeholder = { Text("wss://…", fontFamily = FontFamily.Monospace, fontSize = 13.sp) },
                        textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                        isError = draft.isNotBlank() && !MyDevicesRules.isFinderRelay(draft),
                        modifier = Modifier.weight(1f).padding(vertical = 8.dp),
                    )
                    TextButton(
                        onClick = { viewModel.setFinderRelays(relays + draft.trim()); draft = "" },
                        enabled = !busy && MyDevicesRules.isFinderRelay(draft) && draft.trim() !in relays,
                    ) { Text("Add") }
                }
            }

            MeshSection(
                "Middle Server",
                footer = "How this phone reaches anyone outside My Devices: the photos of people you follow, a browser vault, and visitors to your home vault. They never get this phone's address; the middle server does see it. With None, follows' photos load from their web addresses instead, a browser vault only connects on the same network, and the home vault takes no visitors.",
            ) {
                MIDDLE_SERVERS.forEachIndexed { i, (key, label) ->
                    if (i > 0) MeshDivider()
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()
                        .clickable(enabled = !busy) { viewModel.setMiddleServer(key) }.padding(vertical = 14.dp)) {
                        Text(label, color = PrimaryText, fontSize = 16.sp, modifier = Modifier.weight(1f))
                        if (settings.middleServer == key) Icon(Icons.Filled.Check, contentDescription = "Selected", tint = colors.primary)
                    }
                }
            }

            MeshSection(null) {
                Text("Reset to defaults", color = colors.primary, fontSize = 16.sp,
                    modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) { viewModel.resetAdvanced() }.padding(vertical = 14.dp))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

internal val MIDDLE_SERVERS = listOf(
    FipsMeshSettings.MIDDLE_PUBLIC to "Public (fips1, fips2.iris.to)",
    FipsMeshSettings.MIDDLE_NONE to "None",
)
