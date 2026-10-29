package com.nostrvault.ui.screens.live

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.LiveChatService
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.FullscreenExit

/**
 * The stream sideways and edge to edge, with the system bars hidden. The chat
 * is hidden, or laid over the right of the video ([chatShown], toggled by the
 * chat button); its lines open profiles and mute or report as they do in the
 * portrait chat. Back, or the exit button, returns to the portrait page, and
 * the phone's own orientation is given back as it was.
 */
@OptIn(UnstableApi::class)
@Composable
internal fun LiveFullScreen(
    player: Player,
    messages: List<LiveChatService.ChatEntry>,
    profiles: Map<String, FeedProfile>,
    onExit: () -> Unit,
    onOpenProfile: (String) -> Unit,
    onMute: (String) -> Unit,
    onReport: (LiveChatService.ChatEntry) -> Unit,
) {
    var chatShown by rememberSaveable { mutableStateOf(false) }
    val activity = LocalContext.current.findActivity()
    val view = LocalView.current
    BackHandler(onBack = onExit)

    DisposableEffect(activity) {
        val window = activity?.window
        val before = activity?.requestedOrientation
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        val insets = window?.let { WindowCompat.getInsetsController(it, view) }
        insets?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        insets?.hide(WindowInsetsCompat.Type.systemBars())
        onDispose {
            insets?.show(WindowInsetsCompat.Type.systemBars())
            if (before != null) activity.requestedOrientation = before
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    this.player = player
                    useController = true
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                }
            },
            // The portrait page takes the player back when this goes.
            onRelease = { it.player = null },
            modifier = Modifier.fillMaxSize(),
        )
        if (chatShown) {
            Box(
                Modifier
                    .align(Alignment.CenterEnd)
                    .fillMaxHeight()
                    .fillMaxWidth(0.38f)
                    .background(Color.Black.copy(alpha = 0.55f))
                    .safeDrawingPadding()
                    .padding(top = 48.dp),
            ) {
                LiveChat(
                    messages = messages,
                    profiles = profiles,
                    onReport = onReport,
                    onOpenProfile = onOpenProfile,
                    onMute = onMute,
                    compact = true,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Row(
            Modifier
                .align(Alignment.TopEnd)
                .safeDrawingPadding()
                .padding(6.dp),
        ) {
            OverlayButton(
                icon = androidx.compose.material.icons.Icons.AutoMirrored.Filled.Chat,
                label = if (chatShown) "Hide chat" else "Show chat",
                onClick = { chatShown = !chatShown },
            )
            OverlayButton(icon = androidx.compose.material.icons.Icons.Filled.FullscreenExit, label = "Exit full screen", onClick = onExit)
        }
    }
}

@Composable
private fun OverlayButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(36.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape),
        ) {
            Icon(icon, contentDescription = label, tint = Color.White)
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
