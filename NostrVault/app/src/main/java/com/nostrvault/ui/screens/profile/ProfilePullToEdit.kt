package com.nostrvault.ui.screens.profile

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animate
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * How far the page is pulled past its top, in px. The page moves half as far
 * as the finger, as a stretched edge does.
 */
internal class PullToEditState(private val thresholdPx: Float) {
    var distance by mutableFloatStateOf(0f)
        private set

    val isArmed: Boolean get() = distance >= thresholdPx
    val progress: Float get() = (distance / thresholdPx).coerceIn(0f, 1f)

    /** Moves the pull by a finger drag of [dy] px; returns how much of it the pull took. */
    fun drag(dy: Float): Float {
        val before = distance
        distance = (distance + dy * DRAG_RATE).coerceAtLeast(0f)
        return (distance - before) / DRAG_RATE
    }

    fun settle(to: Float) { distance = to }

    companion object {
        const val DRAG_RATE = 0.5f
        val threshold: Dp = 96.dp
    }
}

/**
 * Pulling the top of [content] down past a mark and letting go calls
 * [onTrigger] (iOS #456 `pullToEdit`). A label under the toolbar says what
 * letting go will do; pulling back above the mark first cancels.
 * [labelTop] is how far down the page's top bar reaches.
 */
@Composable
internal fun PullToEditBox(
    labelTop: Dp,
    onTrigger: () -> Unit,
    content: @Composable () -> Unit,
) {
    val thresholdPx = with(LocalDensity.current) { PullToEditState.threshold.toPx() }
    val state = remember(thresholdPx) { PullToEditState(thresholdPx) }
    val trigger by rememberUpdatedState(onTrigger)
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(state) {
        // A tick as the pull crosses the mark, as on iOS.
        var wasArmed = false
        snapshotFlow { state.isArmed }.collect { armed ->
            if (armed && !wasArmed) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            wasArmed = armed
        }
    }
    val connection = remember(state) {
        object : NestedScrollConnection {
            // Pushing back up shrinks the pull before the list scrolls.
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset =
                if (source == NestedScrollSource.UserInput && available.y < 0 && state.distance > 0) {
                    Offset(0f, state.drag(available.y))
                } else Offset.Zero

            // Only what the list could not scroll, at its top, becomes pull.
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset =
                if (source == NestedScrollSource.UserInput && available.y > 0) {
                    Offset(0f, state.drag(available.y))
                } else Offset.Zero

            override suspend fun onPreFling(available: Velocity): Velocity {
                if (state.distance <= 0f) return Velocity.Zero
                if (state.isArmed) trigger()
                animate(state.distance, 0f) { value, _ -> state.settle(value) }
                return available
            }
        }
    }
    Box(Modifier.fillMaxSize().nestedScroll(connection)) {
        Box(Modifier.fillMaxSize().graphicsLayer { translationY = state.distance }) { content() }
        PullToEditLabel(
            state,
            Modifier
                .align(Alignment.TopCenter)
                .padding(top = labelTop + 10.dp),
        )
    }
}

/**
 * Lands on the banner, which can be any picture: a dark capsule until
 * armed, then the accent.
 */
@Composable
private fun PullToEditLabel(state: PullToEditState, modifier: Modifier = Modifier) {
    // Read through derivedStateOf so a drag recomposes the label only when
    // it arms or disarms; the per-frame values are read in the layer.
    val armed by remember(state) { derivedStateOf { state.isArmed } }
    val background by animateColorAsState(
        if (armed) LocalNostrVaultColors.current.primary else Color.Black.copy(alpha = 0.6f),
        label = "pull-to-edit",
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier
            .graphicsLayer {
                val p = state.progress
                alpha = (p * 1.6f - 0.2f).coerceIn(0f, 1f)
                scaleX = 0.85f + 0.15f * p
                scaleY = scaleX
            }
            .height(32.dp)
            .background(background, CircleShape)
            .padding(horizontal = 14.dp)
            // The Edit Profile button is the way in for TalkBack.
            .clearAndSetSemantics {},
    ) {
        Icon(NostrVaultIcons.Edit, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
        Text(
            if (armed) "Release to edit profile" else "Pull to edit profile",
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
