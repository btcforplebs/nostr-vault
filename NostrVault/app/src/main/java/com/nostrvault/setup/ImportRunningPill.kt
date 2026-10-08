package com.nostrvault.setup

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.StateFlow

/**
 * "Importing · notes from Mar 2024": shown over the app while an import runs
 * after setup ("Keep it running in the background", or an import started
 * from Settings). Not a button, so it takes no touches. Same as iOS
 * `ImportRunningPill`.
 */
@Composable
fun ImportRunningPill(
    isImporting: StateFlow<Boolean>,
    statusMessage: StateFlow<String>,
    hasCompletedSetup: Boolean,
    modifier: Modifier = Modifier,
) {
    val importing by isImporting.collectAsState()
    val status by statusMessage.collectAsState()
    val text = "Importing · " + ImportTourStage.shortText(ImportTourStage.from(status, completed = false))
    AnimatedVisibility(
        visible = importing && hasCompletedSetup,
        enter = fadeIn(),
        exit = fadeOut(),
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(50))
                .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(50))
                .padding(horizontal = 14.dp, vertical = 8.dp)
                .clearAndSetSemantics { contentDescription = text },
        ) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
            Text(
                text = text,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
