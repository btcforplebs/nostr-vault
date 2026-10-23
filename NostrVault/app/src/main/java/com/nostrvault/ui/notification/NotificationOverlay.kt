package com.nostrvault.ui.notification

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.nostrvault.service.InAppBannerBus
import com.nostrvault.service.PillEnd
import kotlinx.coroutines.delay

/** How long a mention, reply or DM that arrived stays up: a result, 3 s (`docs/pills.md`). */
private const val ACTIVITY_VISIBLE_MS = 3_000L

/**
 * The lane: the one place every pill draws, top-centre under the top bar.
 * Placed in the activity's root Box at Alignment.TopCenter, above the
 * full-screen media viewer so the viewer's own results land here too.
 *
 * Draws, in level order, the manager's pills, with the post countdown
 * ([postAction]) first among the results and activity that arrived while
 * the app was open ([InAppBannerBus]) after them, then [ambient] pills the
 * app hosts here (the running import). The same order as iOS `AppBannerStack`. Each goes through a [PillSlot], so the
 * lane shows at most two and hides ambient ones while anything else is up.
 * The pills a screen draws itself (New Posts, the WoT rebuild) read
 * [PillLane.hidesAmbient] instead.
 */
@Composable
fun NotificationOverlay(
    notificationManager: NotificationManager,
    modifier: Modifier = Modifier,
    postAction: @Composable () -> Unit = {},
    ambient: @Composable () -> Unit = {},
) {
    val notifications by notificationManager.notifications.collectAsState()
    val banner by InAppBannerBus.current.collectAsState()

    // Keyed by the whole banner: a folded followers' pill whose count went
    // up in place gets its full time again.
    LaunchedEffect(banner) {
        val id = banner?.id ?: return@LaunchedEffect
        delay(ACTIVITY_VISIBLE_MS)
        InAppBannerBus.dismiss(id, PillEnd.TIMED_OUT)
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(top = PillStyle.laneTop)
            .padding(horizontal = PillStyle.sideMargin),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        PillLevel.entries.forEach { level ->
            if (level == PillLevel.RESULT) postAction()
            // Newest first within a level: the manager's list already is.
            notifications.filter { it.level == level }.forEach { notification ->
                key(notification.id) {
                    PillSlot(notification.id, level) {
                        NotificationPill(notification, notificationManager)
                    }
                }
            }
            if (level == PillLevel.RESULT) {
                banner?.let { current ->
                    key(current.laneId) {
                        PillSlot(current.laneId, PillLevel.RESULT) {
                            ActivityPill(current)
                        }
                    }
                }
            }
        }
        ambient()
    }
}

@Composable
private fun NotificationPill(notification: AppNotification, notificationManager: NotificationManager) {
    when (notification) {
        is ZapNotification -> ZapPill(notification) { notificationManager.dismiss(notification.id) }
        is FollowNotification -> FollowPill(notification) {
            notificationManager.dismiss(notification.id)
            notification.undo?.invoke()
        }
        is ErrorNotification -> ErrorPill(notification) { notificationManager.dismiss(notification.id) }
        is ActionToast -> ActionToastPill(notification)
        is FeedbackNotification -> FeedbackPill(notification)
        is FilterNoteNotification -> com.nostrvault.ui.components.FilterNoteContent(notification.note)
        is UploadNotification -> UploadPill(notification)
        is UnlikeCountdown -> UnlikeCountdownPill(notification) {
            notificationManager.undoUnlikeCountdown()
        }
    }
}
