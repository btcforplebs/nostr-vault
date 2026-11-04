package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.ListHistoryScan
import com.nostrvault.ui.theme.SecondaryText

/**
 * Moving in's choice to also look for older versions of the owner's lists on
 * history relays ([ListHistoryScan]). Off by default; the caller passes it to
 * [com.nostrvault.service.RelayImportService.importNotes]. Twin of iOS
 * `ListHistoryOptInToggle.swift`.
 */
@Composable
fun ListHistoryOptInRow(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    textColor: Color = SecondaryText,
    accent: Color = Color(0xFFE67326),
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
            .testTag("import.listHistory.optIn"),
    ) {
        Text(ListHistoryScan.OPT_IN_LABEL, color = textColor, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(12.dp))
        Switch(
            checked = checked,
            onCheckedChange = null,
            colors = SwitchDefaults.colors(checkedTrackColor = accent),
        )
    }
}
