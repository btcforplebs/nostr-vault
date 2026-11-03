package com.nostrvault.ui.screens.shareportal

import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/** "Shared for another account" and a switch button, for cards that publish. */
@Composable
internal fun ShareAccountSwitchRow(intent: ShareIntent, needsSwitch: Boolean, onSwitchAccount: (String) -> Unit) {
    val wanted = intent.account ?: return
    if (!needsSwitch) return
    Text("This was shared for another of your accounts.", color = SecondaryText)
    OutlinedButton(onClick = { onSwitchAccount(wanted) }) { Text("Switch to that account") }
}
