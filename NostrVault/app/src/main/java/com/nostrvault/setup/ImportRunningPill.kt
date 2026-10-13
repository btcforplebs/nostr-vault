package com.nostrvault.setup

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.notification.PillLevel
import com.nostrvault.ui.notification.PillSize
import com.nostrvault.ui.notification.PillSlot
import com.nostrvault.ui.notification.PillStyle
import com.nostrvault.ui.notification.PillText
import com.nostrvault.ui.notification.PillTone
import com.nostrvault.ui.notification.pillCapsule
import kotlinx.coroutines.flow.StateFlow

/**
 * "Importing · notes from Mar 2024": in the lane while an import runs after
 * setup ("Keep it running in the background", or an import started from
 * Settings). Ambient, so it steps aside while anything else shows, and
 * small, since it takes no touches. Same as iOS `ImportRunningPill`.
 */
@Composable
fun ImportRunningPill(
    isImporting: StateFlow<Boolean>,
    statusMessage: StateFlow<String>,
    hasCompletedSetup: Boolean,
) {
    val importing by isImporting.collectAsState()
    val status by statusMessage.collectAsState()
    if (!(importing && hasCompletedSetup)) return
    val text = "Importing · " + ImportTourStage.shortText(ImportTourStage.from(status, completed = false))
    PillSlot("import-running", PillLevel.AMBIENT) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
            modifier = Modifier
                .pillCapsule(PillTone.ACCENT, PillSize.SMALL)
                .clearAndSetSemantics { contentDescription = text },
        ) {
            CircularProgressIndicator(color = PillStyle.textColor, strokeWidth = 1.5.dp, modifier = Modifier.size(PillSize.SMALL.icon))
            PillText(text, PillSize.SMALL)
        }
    }
}
