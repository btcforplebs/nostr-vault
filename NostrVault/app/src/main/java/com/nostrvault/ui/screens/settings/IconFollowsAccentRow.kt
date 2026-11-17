package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.IconAccentApply
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.OnAccent
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * Settings > Appearance > Accent > "Icon follows accent": the home-screen icon
 * takes the nearest of the eight accent colours (twin of the iOS toggle in
 * AccentSettingsSection.swift). Kept on this phone; off by default.
 */
@Composable
internal fun IconFollowsAccentRow(accentSetting: String) {
    val context = LocalContext.current
    var on by remember { mutableStateOf(IconAccentApply.follows(context)) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Icon Follows Accent", color = PrimaryText, fontSize = 15.sp)
            Text(
                text = "The home-screen icon takes the nearest of the eight colours. Your launcher may take a few seconds to show it.",
                color = SecondaryText,
                fontSize = 13.sp,
            )
        }
        Switch(
            checked = on,
            onCheckedChange = {
                on = it
                IconAccentApply.setFollows(context, it, accentSetting)
            },
            modifier = Modifier.testTag("appearance.iconFollowsAccent"),
            colors = SwitchDefaults.colors(
                checkedThumbColor = OnAccent,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
            ),
        )
    }
}
