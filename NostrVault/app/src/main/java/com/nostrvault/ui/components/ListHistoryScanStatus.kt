package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.ListHistoryScan
import com.nostrvault.service.RelayImportService
import com.nostrvault.ui.theme.SecondaryText

/**
 * While Moving in looks for older list versions: Skip (what was found so far
 * is kept and the import carries on). After: the plain count. Nothing when
 * the scan didn't run. Twin of iOS `ListHistoryScanStatus.swift`.
 */
@Composable
fun ListHistoryScanStatus(
    service: RelayImportService,
    modifier: Modifier = Modifier,
    textColor: Color = SecondaryText,
    accent: Color = Color(0xFFE67326),
    /** false where the screen's own status line already says it (the import tour). */
    showsLooking: Boolean = true,
) {
    val scanning by service.listHistoryScanning.collectAsState()
    val note by service.listHistoryNote.collectAsState()
    if (scanning) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier.fillMaxWidth()) {
            if (showsLooking) Text(ListHistoryScan.LOOKING, color = textColor, fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            TextButton(
                onClick = service::skipListHistoryScan,
                modifier = Modifier.heightIn(min = 48.dp).testTag("import.listHistory.skip"),
            ) {
                Text("Skip", color = accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    } else {
        note?.let {
            Text(it, color = textColor, fontSize = 12.sp, modifier = modifier.testTag("import.listHistory.note"))
        }
    }
}
