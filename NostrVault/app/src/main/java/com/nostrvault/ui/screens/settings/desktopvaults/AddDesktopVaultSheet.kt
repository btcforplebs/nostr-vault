package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.DesktopVaultKind
import com.nostrvault.ui.screens.settings.SectionLabel
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.Surface2

/**
 * Desktop Vaults › Add (Desktop Vaults P7, §2.7): pair it over the Mesh, type its web address, or both. A newly paired
 * Mac or Linux box joins the list by itself ([com.nostrvault.relay.DesktopVaultsRules.followingDevices]), so Pair
 * just opens the two-scan pairing; a paired desktop whose Vault was deleted can be picked again here. A host another
 * Vault has is refused (§2.5 rule 4). Nothing is published: list switches are on the Vault's own page, off. iOS twin:
 * `AddDesktopVaultSheet.swift` (P4 #2511).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AddDesktopVaultSheet(viewModel: DesktopVaultsViewModel, onPair: () -> Unit, onDismiss: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    val leftOut = remember { viewModel.pairedLeftOut() }
    var name by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf(DesktopVaultKind.MAC) }
    var address by remember { mutableStateOf("") }
    var meshNpub by remember { mutableStateOf<String?>(null) }
    var refusal by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface2,
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Text("Add a desktop Vault", color = PrimaryText, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
                TextButton(
                    onClick = {
                        refusal = viewModel.add(name, address, meshNpub, kind)
                        if (refusal == null) onDismiss()
                    },
                    enabled = address.isNotBlank() || meshNpub != null,
                ) { Text("Add") }
            }

            SectionLabel("Over the Mesh")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clickable(onClick = onPair).padding(vertical = 10.dp),
            ) {
                Icon(Icons.Filled.QrCodeScanner, contentDescription = null, tint = accent, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(12.dp))
                Text("Pair a new desktop over the Mesh", color = accent, fontSize = 15.sp)
            }
            if (leftOut.isNotEmpty()) {
                Text("Paired desktop", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.padding(top = 6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = meshNpub == null, onClick = { meshNpub = null }, label = { Text("None") })
                    for (device in leftOut) {
                        val label = device.name.ifBlank { device.npub.take(12) + "…" }
                        FilterChip(selected = meshNpub == device.npub, onClick = {
                            meshNpub = device.npub
                            if (name.isEmpty()) name = device.name
                        }, label = { Text(label) })
                    }
                }
            }
            DesktopVaultNote("A desktop you pair joins your Vaults by itself. Drafts and private files go over the Mesh only.")

            DesktopVaultGap()
            SectionLabel("Web address")
            OutlinedTextField(
                value = address, onValueChange = { address = it; refusal = null },
                placeholder = { Text("https://vault.example.com") }, singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
            DesktopVaultNote(if (meshNpub == null) DesktopVaultText.WEB_ONLY_NOTE else "With both, the Mesh comes first and the web address is the fallback.")

            DesktopVaultGap()
            SectionLabel("Name")
            OutlinedTextField(value = name, onValueChange = { name = it }, placeholder = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                for (k in DesktopVaultKind.entries) {
                    FilterChip(selected = kind == k, onClick = { kind = k }, label = { Text(DesktopVaultText.kindLabel(k)) })
                }
            }
            refusal?.let { DesktopVaultNote(it, warn = true) }
            DesktopVaultGap()
        }
    }
}
