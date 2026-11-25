package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultList
import com.nostrvault.relay.DesktopVaultsEditing
import com.nostrvault.ui.screens.settings.SectionLabel
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/** One "From your Vault <name>" row and which list it is on ("Relay", "DM inbox", "Media server"). */
internal data class DesktopVaultEntry(val entry: DesktopVaultsEditing.ListedEntry, val list: String)

/** The desktop Vault entries of the published lists, in list order: relays, then DM inbox, then media servers. */
internal fun desktopVaultEntries(
    relays: List<List<String>> = emptyList(), inboxes: List<String> = emptyList(), servers: List<String> = emptyList(),
    vaults: List<DesktopVault>,
): List<DesktopVaultEntry> =
    DesktopVaultsEditing.listedEntries(relays, DesktopVaultList.RELAYS, vaults).map { DesktopVaultEntry(it, "Relay") } +
        DesktopVaultsEditing.listedEntries(inboxes.map { listOf("relay", it) }, DesktopVaultList.INBOX, vaults).map { DesktopVaultEntry(it, "DM inbox") } +
        DesktopVaultsEditing.listedEntries(servers.map { listOf("server", it) }, DesktopVaultList.MEDIA, vaults)
            .map { DesktopVaultEntry(it, if (it.mesh) "Media over the Mesh · Beta" else "Media server") }

/**
 * "From your Vault <name>": the desktop Vault entries of the published lists, read only, on Settings › Relays
 * (Desktop Vaults P7, §2.4). Each opens its Vault's page, where its switches add or remove them; a Save on Relays
 * carries them through as they are. iOS twin: `DesktopVaultEntryRows.swift` (P4 #2511).
 */
@Composable
internal fun DesktopVaultEntryRows(entries: List<DesktopVaultEntry>, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    if (entries.isEmpty()) return
    Column(modifier.fillMaxWidth()) {
        SectionLabel("From your desktop Vaults")
        for (item in entries) {
            val vault = item.entry.vault
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clickable { onOpen(vault.id) }.padding(vertical = 6.dp),
            ) {
                Icon(DesktopVaultText.icon(vault.kind), contentDescription = null, tint = DesktopVaultTeal, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("From your Vault ${vault.displayName}", color = PrimaryText, fontSize = 14.sp)
                    Text("${item.list} · ${item.entry.url}", color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                }
            }
        }
        DesktopVaultNote("Set on each Vault's page under Listed publicly. Saving here keeps them as they are.")
    }
}
