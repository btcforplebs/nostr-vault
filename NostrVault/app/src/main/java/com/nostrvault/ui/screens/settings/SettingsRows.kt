package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText

/**
 * The rows the settings pages are built from: a label, an optional (i) with
 * the words from [SettingsHelp], and the control. Shared by Media & Cache,
 * Who Can Reach You and Database & Reset, which were one Advanced page.
 */

@Composable
internal fun SectionLabel(text: String, help: SettingsHelp? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 8.dp)) {
        Text(
            text = text.uppercase(),
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
        )
        if (help != null) InfoButton(help)
    }
}

@Composable
internal fun Caption(text: String) {
    Text(text = text, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
}

/** The label of a row, with its (i) when the setting has one. */
@Composable
internal fun RowLabel(label: String, help: SettingsHelp?, enabled: Boolean = true, modifier: Modifier = Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        Text(label, color = if (enabled) PrimaryText else TertiaryText, fontSize = 15.sp)
        if (help != null) InfoButton(help)
    }
}

@Composable
internal fun ReadOnlyRow(label: String, value: String, help: SettingsHelp? = null) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowLabel(label, help)
        Text(value, color = SecondaryText, fontSize = 15.sp)
    }
}

@Composable
internal fun ToggleRow(
    label: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    help: SettingsHelp? = null,
    enabled: Boolean = true,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        RowLabel(label, help, enabled, Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = colors.primary,
            ),
        )
    }
}

/**
 * A stepper, as iOS: the label, the value (with its [unit], "/ min" say) in
 * secondary text, then − and +.
 */
@Composable
internal fun StepperRow(
    label: String,
    value: Int,
    range: IntRange,
    step: Int,
    help: SettingsHelp? = null,
    unit: String = "",
    onChange: (Int) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        RowLabel(label, help, modifier = Modifier.weight(1f))
        Text("$value$unit", color = SecondaryText, fontSize = 15.sp)
        IconButton(
            onClick = { onChange((value - step).coerceAtLeast(range.first)) },
            enabled = value > range.first,
        ) { Text("−", color = colors.primary, fontSize = 20.sp) }
        IconButton(
            onClick = { onChange((value + step).coerceAtMost(range.last)) },
            enabled = value < range.last,
        ) { Text("+", color = colors.primary, fontSize = 20.sp) }
    }
}

@Composable
internal fun <T> PickerRow(
    label: String,
    options: List<Pair<T, String>>,
    selected: T,
    help: SettingsHelp? = null,
    enabled: Boolean = true,
    onSelect: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = options.firstOrNull { it.first == selected }?.second ?: selected.toString()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        RowLabel(label, help, enabled, Modifier.weight(1f))
        Box {
            Text(
                text = selectedLabel,
                color = if (enabled) LocalNostrVaultColors.current.primary else TertiaryText,
                fontSize = 15.sp,
                modifier = Modifier.clickable(enabled = enabled) { expanded = true }.padding(8.dp),
            )
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { (value, text) ->
                    DropdownMenuItem(
                        text = { Text(text) },
                        onClick = { onSelect(value); expanded = false },
                    )
                }
            }
        }
    }
}
