package com.nostrvault.ui.notification

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.Motion

/**
 * Top-of-screen overlay that renders all active notification pills.
 * Placed inside the root Box of NostrVaultNavHost, at Alignment.TopCenter.
 *
 * Animations match the iOS banner pattern:
 *   enter = slide from top + fade in (spring)
 *   exit  = fade out + scale down to 80%
 */
@Composable
fun NotificationOverlay(
    notificationManager: NotificationManager,
    modifier: Modifier = Modifier,
) {
    val notifications by notificationManager.notifications.collectAsState()

    if (notifications.isEmpty()) return

    Column(
        modifier = modifier
            .fillMaxWidth()
            .statusBarsPadding()
            // Below the top bar (8dp + a 48dp pill row + 8dp), not over its
            // pills: the feed's filter buttons stay readable and tappable while
            // a zap, upload or error pill is showing. iOS parity: #113.
            .padding(top = 64.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        notifications.forEach { notification ->
            key(notification.id) {
                // This exact drop-in / shrink-away pair is the app's one pill
                // transition; it lives in Motion so the Reduce Motion variant —
                // a cross-fade with neither the slide nor the scale — only had
                // to be written once.
                val (pillEnter, pillExit) = Motion.pillTransition
                AnimatedVisibility(
                    visible = true,
                    enter = pillEnter,
                    exit = pillExit,
                ) {
                    when (notification) {
                        is ZapNotification -> ZapPill(notification)
                        is FollowNotification -> FollowPill(notification)
                        is ErrorNotification -> ErrorPill(notification)
                        is ActionToast -> ActionToastPill(notification)
                        is UploadNotification -> UploadPill(notification)
                        is UnlikeCountdown -> UnlikeCountdownPill(notification) {
                            notificationManager.cancelUnlikeCountdown()
                        }
                    }
                }
            }
        }
    }
}
