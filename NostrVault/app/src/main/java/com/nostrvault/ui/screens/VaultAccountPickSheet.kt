package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText

/** The question on the sheet; iOS VaultAccountPickButton's dialog (#1772). */
internal const val PICK_ACCOUNT_TITLE = "Reply or react as"

/**
 * A Vault line that tagged several of your accounts: which one replies or reacts. Picking switches to it and opens the
 * line, as a tapped notification does. Twin of iOS `VaultAccountPickButton` (#1772).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VaultAccountPickSheet(
    accounts: List<String>,
    profiles: Map<String, FeedProfile>,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = SecondaryGroupedBg) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text(
                PICK_ACCOUNT_TITLE,
                color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
            for (hex in accounts) {
                val profile = profiles[hex]
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 52.dp)
                        .clickable(role = Role.Button) { onPick(hex) }
                        .padding(horizontal = 20.dp, vertical = 8.dp),
                ) {
                    AvatarImage(url = profile?.pictureURL, pubkey = hex, size = 36.dp, displayName = profile?.bestName)
                    Column {
                        Text(profile?.bestName ?: ("npub…" + hex.takeLast(6)), color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                        profile?.nip05?.takeIf { it.isNotBlank() }?.let { Text(it, color = SecondaryText, fontSize = 12.sp) }
                    }
                }
            }
        }
    }
}
