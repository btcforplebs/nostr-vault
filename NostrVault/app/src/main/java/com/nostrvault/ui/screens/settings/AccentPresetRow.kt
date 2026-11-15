package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.AccentPalette
import com.nostrvault.ui.theme.Ink
import com.nostrvault.ui.theme.TertiaryText

/**
 * Settings > Appearance > Accent: the eight ready-made colours, a colour
 * wheel for any other pick (AccentWheel.kt) and a preview of the pick in both
 * modes (twin of AccentSettingsSection.swift).
 */
@Composable
fun AccentPresetRow(setting: String, onPick: (String) -> Unit) {
    val picked = AccentPalette.hex(setting)
    SettingHeading("Accent")
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        AccentPalette.presets.forEach { preset ->
            val on = preset.hex == picked
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .border(2.dp, if (on) Ink else Color.Transparent, CircleShape)
                    .clickable(role = Role.RadioButton) { onPick(AccentPalette.setting(preset.hex)) }
                    .semantics { contentDescription = preset.name; selected = on }
                    .testTag("appearance.accent.${preset.name}"),
            ) {
                Box(Modifier.size(28.dp).clip(CircleShape).background(AccentPalette.swatch(preset.hex)))
            }
        }
    }
    AccentCustomRow(picked, onPick)
    Spacer(Modifier.height(10.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        AccentPreview(setting, light = false, Modifier.weight(1f))
        AccentPreview(setting, light = true, Modifier.weight(1f))
    }
    Text(
        if (AccentPalette.shiftsInLight(picked)) "This colour is too pale to read on white, so Light mode uses a deeper shade of it."
        else "Buttons, links and highlights use this colour.",
        color = TertiaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 6.dp),
    )
}

/** One mode's look, drawn with that mode's fixed values whatever mode the app is in. */
@Composable
internal fun AccentPreview(setting: String, light: Boolean, modifier: Modifier) {
    val ramp = AccentPalette.ramp(setting, light)
    val page = if (light) Color(0xFFF6F1EB) else Color.Black
    val ink = if (light) Color.Black else Color.White
    val line = if (light) Color(0x291C1C1E) else Color(0x24FFFFFF)
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(page)
            .border(1.dp, line, RoundedCornerShape(10.dp))
            .padding(10.dp),
    ) {
        Text(if (light) "Light" else "Dark", color = ink.copy(alpha = 0.6f), fontSize = 12.sp)
        Spacer(Modifier.height(6.dp))
        Text(
            "Follow",
            color = ramp.onAccent,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(ramp.scheme.primary)
                .padding(horizontal = 14.dp, vertical = 6.dp),
        )
        Spacer(Modifier.height(6.dp))
        Text("nostrvault.app", color = ramp.scheme.primary, fontSize = 13.sp)
    }
}
