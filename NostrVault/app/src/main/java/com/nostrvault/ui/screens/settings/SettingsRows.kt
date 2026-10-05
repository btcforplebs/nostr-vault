package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Rows shared by the settings pages that iOS splits out of the old Android
 * "Advanced" screen (Media & Cache, Who Can Reach You, Database & Reset).
 * The page title always equals the row name in the Settings list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsPage(
    title: String,
    onBack: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            content()
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
internal fun SettingsSectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = modifier.padding(bottom = 8.dp),
    )
}

@Composable
internal fun SettingsCaption(text: String) {
    Text(text = text, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
}

/** A row label with the setting's (i) button beside it, as iOS's `.settingInfo`. */
@Composable
private fun RowLabel(label: String, help: SettingsHelp?, modifier: Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        Text(label, color = PrimaryText, fontSize = 15.sp)
        if (help != null) InfoButton(help)
    }
}

@Composable
internal fun SettingsToggleRow(
    label: String,
    checked: Boolean,
    help: SettingsHelp? = null,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        RowLabel(label, help, Modifier.weight(1f))
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

/** iOS Stepper: label on the left, the value then − / + on the right. */
@Composable
internal fun SettingsStepperRow(
    label: String,
    value: Int,
    range: IntRange,
    step: Int = 1,
    valueText: String = value.toString(),
    help: SettingsHelp? = null,
    onChange: (Int) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        RowLabel(label, help, Modifier.weight(1f))
        Text(valueText, color = SecondaryText, fontSize = 15.sp)
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
internal fun <T> SettingsPickerRow(
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
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        RowLabel(label, help, Modifier.weight(1f))
        Box {
            Text(
                text = selectedLabel,
                color = if (enabled) LocalNostrVaultColors.current.primary else TertiaryText,
                fontSize = 15.sp,
                modifier = Modifier.clickable(enabled = enabled) { expanded = true }.padding(12.dp),
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

@Composable
internal fun SettingsReadOnlyRow(label: String, value: String, help: SettingsHelp? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        RowLabel(label, help, Modifier.weight(1f))
        Text(value, color = SecondaryText, fontSize = 15.sp)
    }
}

/**
 * Widens a child by [amount] on each side, past its parent's padding, so a
 * full-width list row inside a padded page lines up with the screen edges.
 */
internal fun Modifier.bleedHorizontal(amount: Dp): Modifier = layout { measurable, constraints ->
    val extra = amount.roundToPx()
    val placeable = measurable.measure(
        constraints.copy(
            minWidth = constraints.minWidth + 2 * extra,
            maxWidth = constraints.maxWidth + 2 * extra,
        )
    )
    layout(placeable.width - 2 * extra, placeable.height) { placeable.place(-extra, 0) }
}
