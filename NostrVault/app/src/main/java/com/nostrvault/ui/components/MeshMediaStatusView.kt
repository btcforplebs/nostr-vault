package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.fips.MeshMediaPhase
import com.nostrvault.fips.MeshMediaStatus

/**
 * What a photo shows in its place while its owner's vault is asked over the
 * FIPS mesh, or after that failed: iOS `MeshMediaStatusView`, the web's
 * `MeshBox`, same words. Nothing while the photo loads as usual or once it
 * is drawn. Lay it over the image ([Modifier.matchParentSize]); [compact]
 * is for grid tiles, where only the spinner and a short line fit.
 */
@Composable
fun MeshMediaStatusOverlay(
    url: String?,
    modifier: Modifier = Modifier,
    video: Boolean = false,
    compact: Boolean = false,
) {
    val phases by MeshMediaStatus.phases.collectAsState()
    val phase = MeshMediaStatus.phaseFor(phases, url) ?: return
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier.background(Color.Black.copy(alpha = 0.45f)),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(if (compact) 4.dp else 8.dp),
            modifier = Modifier.padding(if (compact) 4.dp else 12.dp),
        ) {
            if (phase == MeshMediaPhase.MeshLookup) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(if (compact) 16.dp else 22.dp),
                )
            }
            Text(
                text = phase.text(video),
                color = Color.White.copy(alpha = 0.9f),
                fontSize = if (compact) 10.sp else 13.sp,
                textAlign = TextAlign.Center,
                maxLines = if (compact) 2 else 3,
            )
        }
    }
}
