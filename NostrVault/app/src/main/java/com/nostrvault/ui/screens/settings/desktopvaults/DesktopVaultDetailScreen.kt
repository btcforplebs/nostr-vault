package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Language
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.fips.MeshPairing
import com.nostrvault.relay.DesktopVault
import com.nostrvault.ui.screens.settings.ReadOnlyRow
import com.nostrvault.ui.screens.settings.SectionLabel
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * Settings › Desktop Vaults › one Vault (Desktop Vaults P7, §2.7): its name, how it is reached (Mesh, web or both),
 * its last copy, which public lists name it ([DesktopVaultListedSection]) and Delete, which asks whether to take it
 * out of those lists too (§2.5 rule 5). iOS twin: `DesktopVaultDetailView.swift` (P4 #2511).
 */
@Composable
fun DesktopVaultDetailScreen(
    vaultId: String,
    onBack: () -> Unit,
    onPair: () -> Unit,
    viewModel: DesktopVaultsViewModel = hiltViewModel(),
) {
    val vaults by viewModel.vaults.collectAsState()
    val vault = vaults.firstOrNull { it.id == vaultId }
    LaunchedEffect(Unit) { viewModel.load() }
    if (vault == null) {
        DesktopVaultPage("Desktop Vault", onBack) { DesktopVaultNote("This Vault was deleted.") }
        return
    }
    DesktopVaultPage(vault.displayName, onBack) { DetailBody(vault, viewModel, onBack, onPair) }
}

@Composable
private fun DetailBody(vault: DesktopVault, viewModel: DesktopVaultsViewModel, onBack: () -> Unit, onPair: () -> Unit) {
    var name by remember(vault.id) { mutableStateOf(vault.name) }
    // Saved when the page closes, as iOS's onDisappear.
    val latestName by rememberUpdatedState(name)
    DisposableEffect(vault.id) { onDispose { viewModel.rename(vault.id, latestName) } }

    SectionLabel("Name")
    OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, placeholder = { Text("Name") }, modifier = Modifier.fillMaxWidth())
    ReadOnlyRow("Kind", DesktopVaultText.kindLabel(vault.kind))

    DesktopVaultGap()
    PathsSection(vault, viewModel, onPair)

    val status by produceState<String?>(null, vault.httpsURL) { value = viewModel.statusLine(vault) }
    status?.let {
        DesktopVaultGap()
        SectionLabel("Last copy")
        DesktopVaultNote(it)
    }

    DesktopVaultGap()
    DesktopVaultListedSection(vault, viewModel)

    DesktopVaultGap()
    DeleteSection(vault, viewModel, onDeleted = onBack)
}

@Composable
private fun PathsSection(vault: DesktopVault, viewModel: DesktopVaultsViewModel, onPair: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    val lists by viewModel.lists.collectAsState()
    val loading by viewModel.loading.collectAsState()
    var address by remember(vault.id, vault.httpsURL) { mutableStateOf(vault.httpsURL.orEmpty()) }
    var addressLine by remember { mutableStateOf<String?>(null) }
    // Read with the lists, so it follows them as they load.
    val locked = remember(lists, loading, vault) { viewModel.addressLockedLine(vault) }

    SectionLabel("How it's reached")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Icon(Icons.Filled.Hub, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text("Mesh", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        val npub = vault.meshNpub
        if (npub != null) {
            Text(MeshPairing.shortAddress(npub), color = SecondaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
        } else {
            TextButton(onClick = onPair) { Text("Pair over the Mesh", color = accent) }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
        Icon(Icons.Filled.Language, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text("Web address", color = PrimaryText, fontSize = 15.sp)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = address, onValueChange = { address = it; addressLine = null }, enabled = locked == null, singleLine = true,
            placeholder = { Text("https://vault.example.com") }, textStyle = TextStyle(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
            modifier = Modifier.weight(1f),
        )
        if (address != vault.httpsURL.orEmpty() && locked == null) {
            TextButton(onClick = { addressLine = viewModel.setAddress(vault.id, address) }) { Text("Save") }
        }
    }
    when {
        addressLine != null -> DesktopVaultNote(addressLine!!, warn = true)
        locked != null -> DesktopVaultNote(locked)
    }
    DesktopVaultNote(
        when {
            vault.meshNpub == null -> DesktopVaultText.WEB_ONLY_NOTE
            vault.httpsURL == null -> DesktopVaultText.MESH_ONLY_NOTE
            else -> DesktopVaultText.BOTH_NOTE
        },
    )
}

@Composable
private fun DeleteSection(vault: DesktopVault, viewModel: DesktopVaultsViewModel, onDeleted: () -> Unit) {
    var ask by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var line by remember { mutableStateOf<String?>(null) }
    val done = { why: String? ->
        deleting = false
        if (why == null) onDeleted() else line = why
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (deleting) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text("Taking it out of your lists…", color = SecondaryText, fontSize = 15.sp)
        } else {
            TextButton(onClick = { ask = true }) { Text("Delete this Vault", color = ErrorRed) }
        }
    }
    DesktopVaultNote(line ?: "This phone stops syncing with it. It stays in Your Devices until you remove it there.", warn = line != null)
    if (ask) {
        AlertDialog(
            onDismissRequest = { ask = false },
            title = { Text("Also take ${vault.displayName} out of your public lists?") },
            text = { Text("Yes removes its addresses from your relays, DM inbox and media servers. No leaves them there as ordinary entries.") },
            confirmButton = {
                Column {
                    TextButton(onClick = { ask = false; deleting = true; line = null; viewModel.delete(vault, unlist = true, done) }) { Text("Yes, take it out") }
                    TextButton(onClick = { ask = false; line = null; viewModel.delete(vault, unlist = false, done) }) { Text("No, leave my lists as they are") }
                    TextButton(onClick = { ask = false }) { Text("Cancel") }
                }
            },
        )
    }
}
