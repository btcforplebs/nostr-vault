package com.nostrvault.ui.screens.live

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.Player
import androidx.media3.ui.PlayerView

/**
 * The live screen in a picture-in-picture window: the stream's picture alone,
 * edge to edge, no controls or chat (the window is too small for them, and
 * PiP has its own play/pause). PiP plan lane C.
 */
@Composable
fun LivePiPVideo(player: Player) {
    AndroidView(
        factory = { ctx ->
            PlayerView(ctx).apply {
                this.player = player
                useController = false
            }
        },
        // Let go of the surface, so the screen's own view takes it back after PiP.
        onRelease = { it.player = null },
        modifier = Modifier.fillMaxSize().background(Color.Black),
    )
}
