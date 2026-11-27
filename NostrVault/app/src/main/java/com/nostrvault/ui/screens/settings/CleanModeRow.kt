package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Clean mode's switch (util/CleanMode): mask swear words on screen. Off by
 * default, this device only, never published. On the Muted words page, as
 * on iOS (MutedWordsSettingsView) and web (MutedWords.jsx).
 */
@Composable
internal fun CleanModeRow(on: Boolean, onChange: (Boolean) -> Unit) {
    SectionLabel("Clean mode")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text("Mask swear words, like f***", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(
            checked = on,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = LocalNostrVaultColors.current.primary),
        )
    }
    Caption(
        "Shows swear words as their first letter and asterisks in notes, names, bios, messages and " +
            "notifications. Only on this device. What you write and send is never changed.",
    )
}
