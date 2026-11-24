package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultsRules
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen

/**
 * Media Servers › Added for You (Desktop Vaults P7): every HTTPS desktop Vault, which uploads mirror to whether or not
 * its media switch lists it, each with [health] under it and opening its Vault's page. Replaces the one
 * "Auto-Applied Blossom Server" row of the old slot. iOS: `BlossomSettingsView`'s "Added for You" (P4 #2511).
 */
@Composable
internal fun DesktopVaultMediaRows(vaults: List<DesktopVault>, onOpen: (String) -> Unit, health: @Composable (url: String) -> Unit) {
    val web = vaults.filter { it.httpsURL != null }
    if (web.isEmpty()) return
    Surface(
        color = SuccessGreen.copy(alpha = 0.1f),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(Modifier.padding(12.dp)) {
            Text("Added for You", color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            for (vault in web) {
                val url = "https://" + DesktopVaultsRules.base(vault.httpsURL!!)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().clickable { onOpen(vault.id) }.padding(top = 8.dp),
                ) {
                    Icon(NostrVaultIcons.Check, contentDescription = null, tint = SuccessGreen, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Column {
                        Text("Your Vault ${vault.displayName}", color = PrimaryText, fontSize = 13.sp)
                        Text(url, color = SecondaryText, fontSize = 12.sp)
                    }
                }
                health(url)
            }
            DesktopVaultNote("Uploads also go to each of these. Whether others see one is its Vault's Media servers switch.")
        }
    }
}
