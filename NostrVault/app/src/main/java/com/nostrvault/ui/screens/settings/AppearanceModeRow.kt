package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.AppPalette
import com.nostrvault.ui.theme.BorderHairline
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.Surface3
import com.nostrvault.ui.theme.TertiaryText

/**
 * Settings > Appearance > Mode: Dark / Light / Match Phone, one segmented row
 * (twin of the Mode picker in AppearanceSettingsView.swift).
 */
@Composable
fun AppearanceModeRow(mode: String, onPick: (String) -> Unit) {
    SettingHeading("Mode")
    Row(
        modifier = Modifier
            .padding(top = 8.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Surface1)
            .border(1.dp, BorderHairline, RoundedCornerShape(10.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        listOf(AppPalette.DARK to "Dark", AppPalette.LIGHT to "Light", AppPalette.SYSTEM to "Match Phone").forEach { (key, title) ->
            val on = mode == key || (key == AppPalette.DARK && mode !in setOf(AppPalette.LIGHT, AppPalette.SYSTEM))
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (on) Surface3 else Surface1)
                    .clickable(role = Role.RadioButton) { onPick(key) }
                    .padding(vertical = 8.dp)
                    .testTag("appearance.mode.$key"),
            ) {
                Text(
                    title,
                    color = if (on) PrimaryText else SecondaryText,
                    fontSize = 14.sp,
                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
    Text(
        "Photos, videos and the trust globe stay dark in every mode.",
        color = TertiaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 6.dp),
    )
}
