package com.nostrvault.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.navigation.DeepLinkTarget
import com.nostrvault.ui.navigation.PendingDeepLink
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.notification.PillButton
import com.nostrvault.ui.notification.PillIcon
import com.nostrvault.ui.notification.PillLevel
import com.nostrvault.ui.notification.PillSize
import com.nostrvault.ui.notification.PillSlot
import com.nostrvault.ui.notification.PillStyle
import com.nostrvault.ui.notification.PillText
import com.nostrvault.ui.notification.PillTone
import com.nostrvault.ui.notification.pillCapsule
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The post countdown and what follows it, as level-2 pills in the lane
 * (`docs/pills.md`): "Posting in 3s" with Edit and Undo, then "Posting…"
 * until a relay takes it, then "Posted". Drawn inside
 * [com.nostrvault.ui.notification.NotificationOverlay].
 * iOS `PostActionNotificationBanner`.
 */
@Composable
fun PendingPostBanner(pendingPostManager: PendingPostManager) {
    // Edit reopens the composer on the post's draft, over whatever is open.
    // The lane sits above the nav host, so it hands the route to the one
    // place that navigates (iOS: SceneDelegate presents ComposeView).
    LaunchedEffect(pendingPostManager) {
        pendingPostManager.editRequest.collect { request ->
            PendingDeepLink.post(DeepLinkTarget(route = composeRouteFor(request)))
        }
    }

    val isShowing by pendingPostManager.isShowing.collectAsState()
    val actionType by pendingPostManager.actionType.collectAsState()
    val timeRemaining by pendingPostManager.timeRemaining.collectAsState()
    val totalSeconds by pendingPostManager.totalSeconds.collectAsState()
    val confirmation by pendingPostManager.confirmation.collectAsState()

    val type = actionType
    val confirmed = confirmation
    if (isShowing && type != null) {
        PillSlot("postAction", PillLevel.RESULT) {
            PostActionPill(
                actionType = type,
                timeRemaining = timeRemaining,
                totalSeconds = totalSeconds,
                onUndo = pendingPostManager::cancel,
                onEdit = if (type.canEdit) pendingPostManager::requestEdit else null,
                onDismiss = pendingPostManager::dismissBanner,
            )
        }
    } else if (confirmed != null) {
        key(confirmed.id) {
            PillSlot("postConfirmation-${confirmed.id}", PillLevel.RESULT) {
                PostConfirmationPill(confirmed)
            }
        }
    }
}

/** The icon for each action (iOS `ActionType.icon`). */
private val PendingPostManager.ActionType.icon: ImageVector
    get() = when (this) {
        PendingPostManager.ActionType.NEW_POST -> NostrVaultIcons.Send
        PendingPostManager.ActionType.REPLY -> NostrVaultIcons.Reply
        PendingPostManager.ActionType.QUOTE -> NostrVaultIcons.Quote
        PendingPostManager.ActionType.REPOST -> NostrVaultIcons.Repost
        PendingPostManager.ActionType.DELETE -> NostrVaultIcons.Delete
    }

/** Swipe up past this to hide the pill (iOS `dismissThreshold`). */
private val DismissThreshold = 32.dp

/**
 * "Posting in 3s", a short progress bar, Edit and Undo: an accent capsule
 * whose 44 dp buttons set its height. Swipe it up to hide it; the post
 * still goes out on time. iOS `PostActionPill`.
 */
@Composable
private fun PostActionPill(
    actionType: PendingPostManager.ActionType,
    timeRemaining: Float,
    totalSeconds: Float,
    onUndo: () -> Unit,
    onEdit: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    // Follows the finger on the way up so the gesture feels attached.
    val dragOffset = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val dismissPx = with(density) { DismissThreshold.toPx() }
    val fadePx = with(density) { 80.dp.toPx() }
    val seconds = max(1, ceil(timeRemaining).toInt())

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .offset { IntOffset(0, dragOffset.value.roundToInt()) }
            .alpha(1f - min(1f, abs(dragOffset.value) / fadePx) * 0.6f)
            .draggable(
                orientation = Orientation.Vertical,
                state = rememberDraggableState { delta ->
                    // Upward only; a downward pull doesn't detach the pill.
                    scope.launch { dragOffset.snapTo(min(0f, dragOffset.value + delta)) }
                },
                onDragStopped = {
                    if (dragOffset.value < -dismissPx) onDismiss()
                    dragOffset.animateTo(0f, Motion.panel())
                },
            )
            // The buttons set the height.
            .pillCapsule(PillTone.ACCENT, vertical = 0.dp)
            .semantics {
                contentDescription = "${actionType.label} in $seconds seconds"
                customActions = listOf(CustomAccessibilityAction("Hide") { onDismiss(); true })
            },
    ) {
        PillIcon(actionType.icon)
        Text(
            text = "${actionType.label} in ${seconds}s",
            color = PillStyle.textColor,
            fontSize = PillSize.REGULAR.font,
            fontWeight = PillSize.REGULAR.weight,
            maxLines = 1,
            // Digits keep their width as they count down (iOS .monospacedDigit()).
            style = TextStyle(fontFeatureSettings = "tnum"),
        )
        CountdownBar(fraction = timeRemaining / totalSeconds.coerceAtLeast(0.1f))
        if (onEdit != null) PillButton("Edit", onClick = onEdit)
        PillButton("Undo", onClick = onUndo)
    }
}

/** 60 × 4 dp: white on a 30 % white track, emptying as the time runs out. */
@Composable
private fun CountdownBar(fraction: Float) {
    Box(
        Modifier
            .size(width = 60.dp, height = 4.dp)
            .background(PillStyle.textColor.copy(alpha = 0.3f), CircleShape),
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .background(PillStyle.textColor, CircleShape),
        )
    }
}

/**
 * After the countdown: "Posting…" until a relay takes it, then a green
 * "Posted". If none of the author's write relays takes it after the retries
 * (see PublishTargets), a red "Not posted": a green pill from some other
 * relay is how a reply went missing on 2026-10-25. Based on
 * PostConfirmationPill in ZapNotificationBanner.swift.
 */
@Composable
private fun PostConfirmationPill(confirmation: PendingPostManager.Confirmation) {
    val state = confirmation.state
    val label = when (state) {
        PendingPostManager.Confirmation.State.SENDING -> "${confirmation.actionType.label}…"
        PendingPostManager.Confirmation.State.CONFIRMED -> confirmation.actionType.doneLabel
        PendingPostManager.Confirmation.State.UNCONFIRMED -> "Not posted. None of your relays took it"
    }
    val tone = when (state) {
        PendingPostManager.Confirmation.State.SENDING -> PillTone.ACCENT
        PendingPostManager.Confirmation.State.CONFIRMED -> PillTone.SUCCESS
        PendingPostManager.Confirmation.State.UNCONFIRMED -> PillTone.ERROR
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
        modifier = Modifier
            .pillCapsule(tone)
            .semantics(mergeDescendants = true) { contentDescription = label },
    ) {
        when (state) {
            PendingPostManager.Confirmation.State.SENDING -> CircularProgressIndicator(
                color = PillStyle.textColor,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(PillSize.REGULAR.icon),
            )
            PendingPostManager.Confirmation.State.CONFIRMED -> PillIcon(NostrVaultIcons.Check)
            PendingPostManager.Confirmation.State.UNCONFIRMED -> PillIcon(Icons.Filled.Schedule)
        }
        PillText(label)
    }
}

/**
 * The composer route Edit reopens: the kept draft, with the note it replies
 * to or quotes. Without a draft the text goes in as the prefill.
 */
internal fun composeRouteFor(request: PendingPostManager.EditRequest): String =
    Screen.ComposeNote.createRoute(
        replyToNoteId = request.replyToId,
        quoteToNoteId = request.quoteToId,
        draftId = request.draftId,
        text = request.content.takeIf { request.draftId == null },
    )
