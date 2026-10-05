package com.nostrvault.ui.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.screens.feed.icon
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.math.roundToInt

/**
 * Hold the Feed tab, slide up onto a feed, let go: that feed opens (iOS #239).
 * Let go without moving and the list stays up for a tap; let go anywhere else
 * after sliding and it closes. A plain tap is still the Feed tab.
 *
 * The finger never leaves the tab's own gesture, so the list does not take
 * touches while dragging: the tab hit-tests the finger against the rows'
 * bounds itself, all in root coordinates.
 */
@Stable
object FeedTabPicker {
    var isOpen by mutableStateOf(false)
        private set
    var hovered by mutableStateOf<FeedMode?>(null)
    /** The Feed tab's bounds, root coordinates; the list rises from it. */
    var anchor by mutableStateOf(Rect.Zero)
        private set
    /** Each row's bounds, root coordinates. */
    internal val rowBounds = mutableStateMapOf<FeedMode, Rect>()

    /** The feed on screen, reported by the feed; drives the checkmark. */
    var shownMode by mutableStateOf<FeedMode?>(null)

    /**
     * A pick waiting for the feed screen to apply it. The feed's mode lives in
     * its own ViewModel, which may not exist yet when the pick is made from
     * another tab, so it is held here until the feed takes it.
     */
    val request = MutableStateFlow<FeedMode?>(null)

    /**
     * Closest to the finger first: the list grows upward, so the first feed
     * sits right above the tab. In the reader's order, hidden feeds left out
     * (Edit Feeds, iOS #303).
     */
    val order: List<FeedMode> get() = FeedMenuSettings.menuModes().reversed()

    /** Only feeds still listed: a row hidden since it was laid out keeps its old bounds here. */
    fun modeAt(point: Offset): FeedMode? {
        val listed = order.toSet()
        return feedModeAt(rowBounds.filterKeys { it in listed }, point)
    }

    fun open(from: Rect) {
        anchor = from
        hovered = null
        isOpen = true
    }

    fun close() {
        isOpen = false
        hovered = null
    }
}

/** The row under [point], with 12dp-ish horizontal slack like iOS's insetBy(dx: -12). */
internal fun feedModeAt(rows: Map<FeedMode, Rect>, point: Offset, slackPx: Float = 36f): FeedMode? =
    rows.entries.firstOrNull { (_, r) ->
        point.y >= r.top && point.y < r.bottom && point.x >= r.left - slackPx && point.x < r.right + slackPx
    }?.key

private const val HOLD_MS = 300L

/**
 * The Feed tab's gesture: tap → [onTap]; hold 300 ms → the picker opens, and
 * releasing over a row picks it. [coordinates] are this node's, for mapping
 * the finger into root coordinates.
 */
internal fun Modifier.feedTabHold(
    coordinates: () -> LayoutCoordinates?,
    haptic: HapticFeedback,
    onTap: () -> Unit,
    onPick: (FeedMode) -> Unit,
): Modifier = pointerInput(Unit) {
    val slop = viewConfiguration.touchSlop
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        fun toRoot(p: Offset): Offset = coordinates()?.let { c -> c.localToRoot(p) } ?: p

        if (FeedTabPicker.isOpen) {
            // A touch that starts while the list is up (tap mode) dismisses it.
            do {
                val ev = awaitPointerEvent()
                ev.changes.forEach { it.consume() }
            } while (ev.changes.any { it.pressed })
            FeedTabPicker.close()
            return@awaitEachGesture
        }

        var moved = false
        var released = false
        val held = withTimeoutOrNull(HOLD_MS) {
            while (true) {
                val ev = awaitPointerEvent()
                val change = ev.changes.firstOrNull { it.id == down.id } ?: run { released = true; return@withTimeoutOrNull }
                if (!change.pressed) {
                    released = true
                    return@withTimeoutOrNull
                }
                if ((change.position - down.position).getDistance() > slop) {
                    moved = true
                    return@withTimeoutOrNull
                }
            }
        } == null

        if (!held) {
            if (released && !moved) {
                onTap()
            } else if (moved) {
                // Slid off before the hold landed: neither a tap nor a hold.
                do {
                    val ev = awaitPointerEvent()
                } while (ev.changes.any { it.pressed })
            }
            return@awaitEachGesture
        }

        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        FeedTabPicker.open(coordinates()?.boundsInRoot() ?: Rect.Zero)
        var last = toRoot(down.position)
        while (true) {
            val ev = awaitPointerEvent()
            val change = ev.changes.firstOrNull { it.id == down.id } ?: break
            change.consume()
            last = toRoot(change.position)
            if ((change.position - down.position).getDistance() > slop) moved = true
            if (!change.pressed) break
            val mode = FeedTabPicker.modeAt(last)
            if (mode != FeedTabPicker.hovered) {
                FeedTabPicker.hovered = mode
                if (mode != null) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            }
        }
        val picked = FeedTabPicker.modeAt(last)
        when {
            picked != null -> {
                FeedTabPicker.close()
                onPick(picked)
            }
            moved -> FeedTabPicker.close()
            // Held and let go in place: the list stays up for a tap.
            else -> FeedTabPicker.hovered = null
        }
    }
}

/**
 * The list itself, drawn over the whole window (above the bar) with a dim
 * behind it; a tap on the dim closes it.
 */
@Composable
fun FeedTabPickerOverlay(
    onPick: (FeedMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    val open = FeedTabPicker.isOpen
    val density = LocalDensity.current
    // Subscribed, so an edit shows the next time the list opens.
    val menuStored by FeedMenuSettings.stored.collectAsState()
    val order = remember(menuStored) { FeedMenuSettings.menuModes(menuStored).reversed() }
    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        AnimatedVisibility(visible = open, enter = fadeIn(), exit = fadeOut()) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.28f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClickLabel = "Close feed list",
                    ) { FeedTabPicker.close() },
            )
        }
        var rootOrigin by remember { mutableStateOf(Offset.Zero) }
        val anchor = FeedTabPicker.anchor
        val heightPx = with(density) { maxHeight.toPx() }
        val marginPx = with(density) { 12.dp.toPx() }
        val leftPx = maxOf(marginPx, anchor.left - rootOrigin.x)
        val bottomPx = maxOf(marginPx, heightPx - (anchor.top - rootOrigin.y) + with(density) { 10.dp.toPx() })
        Box(
            Modifier
                .fillMaxSize()
                .onGloballyPositioned { rootOrigin = it.boundsInRoot().topLeft },
        ) {
            AnimatedVisibility(
                visible = open,
                enter = fadeIn() + scaleIn(initialScale = 0.6f, transformOrigin = TransformOrigin(0f, 1f)),
                exit = fadeOut() + scaleOut(targetScale = 0.6f, transformOrigin = TransformOrigin(0f, 1f)),
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .offset { IntOffset(leftPx.roundToInt(), -bottomPx.roundToInt()) },
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier
                        .shadow(18.dp, RoundedCornerShape(22.dp))
                        .clip(RoundedCornerShape(22.dp))
                        .background(SecondaryGroupedBg.copy(alpha = 0.97f))
                        .padding(6.dp),
                ) {
                    for (mode in order) {
                        FeedPickerRow(
                            mode = mode,
                            current = FeedTabPicker.shownMode == mode,
                            hovered = FeedTabPicker.hovered == mode,
                            onClick = {
                                FeedTabPicker.close()
                                onPick(mode)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FeedPickerRow(
    mode: FeedMode,
    current: Boolean,
    hovered: Boolean,
    onClick: () -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    val scale by animateFloatAsState(if (hovered) 1.04f else 1f, label = "feedRowScale")
    val tint = when {
        hovered -> Color.White
        current -> accent
        else -> PrimaryText
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .onGloballyPositioned { FeedTabPicker.rowBounds[mode] = it.boundsInRoot() }
            .scale(scale)
            .width(210.dp)
            .height(42.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (hovered) accent else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
    ) {
        Icon(mode.icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            text = mode.displayName,
            color = tint,
            fontSize = 16.sp,
            fontWeight = if (current) FontWeight.Bold else FontWeight.Medium,
            modifier = Modifier.weight(1f),
        )
        if (current) {
            Icon(NostrVaultIcons.Check, contentDescription = "Current feed", tint = tint, modifier = Modifier.size(15.dp))
        }
    }
}
