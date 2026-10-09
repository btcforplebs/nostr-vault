package com.nostrvault.ui.components

import androidx.compose.animation.*
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Animated bottom banner showing a countdown before a post is published.
 * Provides Cancel and Edit buttons during the countdown.
 */
@Composable
fun PendingPostBanner(
    pendingPostManager: PendingPostManager,
    modifier: Modifier = Modifier,
) {
    val isShowing by pendingPostManager.isShowing.collectAsState()
    val actionType by pendingPostManager.actionType.collectAsState()
    val timeRemaining by pendingPostManager.timeRemaining.collectAsState()
    val totalSeconds by pendingPostManager.totalSeconds.collectAsState()
    val confirmation by pendingPostManager.confirmation.collectAsState()
    val colors = LocalNostrVaultColors.current

    Box(modifier = modifier, contentAlignment = Alignment.BottomCenter) {
        // After the countdown: "Posting…" until a relay takes it, then "Posted".
        // Keeps the last value while animating out so the pill doesn't blank.
        var lastConfirmation by remember { mutableStateOf(confirmation) }
        confirmation?.let { lastConfirmation = it }
        AnimatedVisibility(
            visible = !isShowing && confirmation != null,
            enter = slideInVertically(initialOffsetY = { it }, animationSpec = Motion.bannerIn()) +
                fadeIn(Motion.bannerIn()),
            exit = slideOutVertically(targetOffsetY = { it }, animationSpec = Motion.bannerOut()) +
                fadeOut(Motion.bannerOut()),
        ) {
            lastConfirmation?.let { PostConfirmationPill(it) }
        }

        AnimatedVisibility(
            visible = isShowing,
            enter = slideInVertically(
                initialOffsetY = { it },
                animationSpec = Motion.bannerIn(),
            ) + fadeIn(Motion.bannerIn()),
            exit = slideOutVertically(targetOffsetY = { it }, animationSpec = Motion.bannerOut()) +
                fadeOut(Motion.bannerOut()),
        ) {
            // Swipe the banner away to get on with things — the post still goes out.
            // Accepts either direction: iOS's pill sits at the top so "swipe up" is
            // the natural gesture there, but this banner is anchored BottomCenter,
            // where swiping down is what reads as dismissal. Rather than force one
            // to match the other, both work.
            val dragOffset = remember { Animatable(0f) }
            val scope = rememberCoroutineScope()
            val dismissThresholdPx = with(LocalDensity.current) { 28.dp.toPx() }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .offset { IntOffset(0, dragOffset.value.roundToInt()) }
                    .draggable(
                        orientation = Orientation.Vertical,
                        state = rememberDraggableState { delta ->
                            scope.launch { dragOffset.snapTo(dragOffset.value + delta) }
                        },
                        onDragStopped = {
                            if (abs(dragOffset.value) > dismissThresholdPx) {
                                pendingPostManager.dismissBanner()
                            }
                            dragOffset.animateTo(0f, Motion.snapBack())
                        },
                    )
                    .clip(RoundedCornerShape(16.dp))
                    .background(SecondaryGroupedBg)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                // Progress arc via LinearProgressIndicator
                val progress = timeRemaining / totalSeconds.coerceAtLeast(0.1f)
                CircularProgressIndicator(
                    progress = { progress },
                    color = colors.primary,
                    trackColor = TertiaryGroupedBg,
                    strokeWidth = 3.dp,
                    modifier = Modifier.size(28.dp),
                )

                Spacer(Modifier.width(12.dp))

                // Action label
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = actionType?.label ?: "Pending",
                        color = PrimaryText,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = String.format("%.1fs", timeRemaining),
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }

                // Edit button (only for editable types)
                if (actionType?.canEdit == true) {
                    TextButton(onClick = { pendingPostManager.requestEdit() }) {
                        Text(
                            text = "Edit",
                            color = colors.primary,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }

                // Cancel button
                TextButton(onClick = { pendingPostManager.cancel() }) {
                    Text(
                        text = "Cancel",
                        color = SecondaryText,
                        fontSize = 14.sp,
                    )
                }
            }
        }
    }
}

/**
 * After the countdown: "Posting…" until a relay takes it, then a green
 * "Posted". If no relay confirms after the retries, a grey note instead of a
 * red error. Port of PostConfirmationPill in ZapNotificationBanner.swift.
 */
@Composable
private fun PostConfirmationPill(confirmation: PendingPostManager.Confirmation) {
    val colors = LocalNostrVaultColors.current
    val state = confirmation.state
    val label = when (state) {
        PendingPostManager.Confirmation.State.SENDING -> "${confirmation.actionType.label}…"
        PendingPostManager.Confirmation.State.CONFIRMED -> confirmation.actionType.doneLabel
        PendingPostManager.Confirmation.State.UNCONFIRMED -> "Sent. No relay has confirmed it yet"
    }
    val background = when (state) {
        PendingPostManager.Confirmation.State.SENDING -> when (confirmation.actionType) {
            PendingPostManager.ActionType.REPLY -> Color(0xFF3885F2)
            PendingPostManager.ActionType.QUOTE -> Color(0xFF1FB399)
            PendingPostManager.ActionType.DELETE -> ErrorRed
            else -> colors.primary
        }
        // Same green as iOS's "Followed".
        PendingPostManager.Confirmation.State.CONFIRMED -> Color(0xFF33CC99)
        PendingPostManager.Confirmation.State.UNCONFIRMED -> Color(0xFF595959)
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(vertical = 8.dp)
            .shadow(8.dp, CircleShape)
            .clip(CircleShape)
            .background(background)
            .padding(horizontal = 20.dp, vertical = 10.dp)
            .semantics(mergeDescendants = true) { contentDescription = label },
    ) {
        if (state == PendingPostManager.Confirmation.State.SENDING) {
            CircularProgressIndicator(
                color = Color.White,
                strokeWidth = 2.dp,
                modifier = Modifier.size(12.dp),
            )
        } else {
            Icon(
                imageVector = if (state == PendingPostManager.Confirmation.State.CONFIRMED) {
                    Icons.Default.Check
                } else {
                    Icons.Default.Schedule
                },
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(14.dp),
            )
        }
        Spacer(Modifier.width(6.dp))
        Text(
            text = label,
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}
