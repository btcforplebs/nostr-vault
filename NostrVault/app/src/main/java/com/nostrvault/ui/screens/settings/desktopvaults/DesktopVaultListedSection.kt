package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultList
import com.nostrvault.relay.DesktopVaultPath
import com.nostrvault.relay.DesktopVaultsEditing
import com.nostrvault.relay.DesktopVaultsLists
import com.nostrvault.service.DesktopVaultListEdit
import com.nostrvault.ui.screens.settings.SectionLabel
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.OnAccent
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText

/**
 * A Vault's "Listed publicly" switches (Desktop Vaults P7, §2.3, §2.4): relays (10002), DM inbox (10050) and media
 * servers (10063) by its web address, plus media over the Mesh (10063 `fipsmesh`), Beta and off by default (Logen
 * 13:42Z). There is no mesh relay switch yet (Logen 13:53Z). Each switch reads the newest published list and each tap
 * changes only this Vault's entry in it ([DesktopVaultListEdit], rule 7). A bare IP address is never listed (rule 8).
 * iOS twin: `DesktopVaultListedSection.swift` (P4 #2511).
 */
@Composable
internal fun DesktopVaultListedSection(vault: DesktopVault, viewModel: DesktopVaultsViewModel) {
    val lists by viewModel.lists.collectAsState()
    val loading by viewModel.loading.collectAsState()
    val busy by viewModel.busy.collectAsState()
    var line by remember { mutableStateOf<String?>(null) }
    val ipHost = vault.httpsURL?.let(DesktopVaultsEditing::isIPHost) ?: true

    @Composable
    fun switch(path: DesktopVaultPath, list: DesktopVaultList, title: String, detail: String, enabled: Boolean, beta: Boolean = false) {
        ListedSwitch(
            title, detail, beta,
            checked = viewModel.isListed(vault, path, list),
            enabled = enabled && list in lists && "$path|$list" !in busy,
        ) { on ->
            line = null
            viewModel.set(on, vault, path, list) { line = it }
        }
    }

    SectionLabel("Listed publicly")
    if (vault.httpsURL != null) {
        switch(DesktopVaultPath.WEB, DesktopVaultList.RELAYS, "Your relays", "Others read your posts here", !ipHost)
        switch(DesktopVaultPath.WEB, DesktopVaultList.INBOX, "DM inbox", "Others send you messages here", !ipHost)
        switch(DesktopVaultPath.WEB, DesktopVaultList.MEDIA, "Media servers", "Others load and upload your media here", !ipHost)
    }
    if (vault.meshNpub != null) {
        switch(DesktopVaultPath.MESH, DesktopVaultList.MEDIA, "Media over the Mesh", DesktopVaultText.MESH_MEDIA_DETAIL, true, beta = true)
        val uri = LocalUriHandler.current
        TextButton(onClick = { uri.openUri(DesktopVaultText.NIP_F1_URL) }) { Text("What is this? (NIP-F1)", fontSize = 12.sp) }
    }
    if (loading) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text("Loading your lists…", color = SecondaryText, fontSize = 12.sp)
        }
    }
    val https = vault.httpsURL
    when {
        line != null -> DesktopVaultNote(line!!, warn = true)
        https != null && DesktopVaultsEditing.isIPHost(https) -> DesktopVaultNote(DesktopVaultsEditing.IP_HOST_MESSAGE + " It still syncs over this address.")
        !loading && DesktopVaultList.entries.any { it !in lists } -> DesktopVaultNote(DesktopVaultListEdit.NOT_LOADED_MESSAGE)
        DesktopVaultList.entries.any { l -> lists[l]?.let { DesktopVaultsLists.overGuidance(it, l) } == true } ->
            DesktopVaultNote(DesktopVaultsLists.OVER_GUIDANCE_NOTE)
        else -> DesktopVaultNote(DesktopVaultText.LISTED_NOTE)
    }
}

@Composable
private fun ListedSwitch(title: String, detail: String, beta: Boolean, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, color = if (enabled) PrimaryText else TertiaryText, fontSize = 15.sp)
                if (beta) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Beta", color = colors.primaryText, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.background(colors.primary.copy(alpha = 0.15f), CircleShape).padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
            Text(detail, color = SecondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = checked, onCheckedChange = onChange, enabled = enabled,
            colors = SwitchDefaults.colors(checkedThumbColor = OnAccent, checkedTrackColor = colors.primary),
        )
    }
}
