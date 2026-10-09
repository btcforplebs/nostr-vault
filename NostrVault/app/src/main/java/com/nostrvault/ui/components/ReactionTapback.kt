package com.nostrvault.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventTimeoutCancellationException
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.ui.theme.LikeRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * What a tap or a pick on the reaction button does (iOS #322). Pure, so the
 * rules are testable apart from the view.
 */
object ReactionChoice {
    sealed interface Change {
        data class React(val content: String) : Change
        object Remove : Change
    }

    /** The emoji the tapback bar offers, before its "+". */
    val TAPBACK = listOf("❤️", "🤙", "🔥", "😂", "😮", "😢")

    /** The account's reaction as the button shows it, or null with none. */
    fun shown(isLiked: Boolean, myContent: String?): String? =
        if (!isLiked) null else reactionDisplayEmoji(myContent ?: "+")

    /** A tap reacts with the default, or takes the reaction back. */
    fun forTap(isLiked: Boolean, defaultContent: String): Change =
        if (isLiked) Change.Remove else Change.React(defaultContent)

    /** A picked emoji is sent; picking the one already sent takes it back. */
    fun forPick(isLiked: Boolean, myContent: String?, picked: String): Change =
        if (picked == shown(isLiked, myContent)) Change.Remove else Change.React(picked)

    /** The bar's emoji: the default reaction always among them, first if it isn't a stock one. */
    fun tapbackOptions(defaultContent: String): List<String> {
        val mine = reactionDisplayEmoji(defaultContent)
        if (mine in TAPBACK) return TAPBACK
        return listOf(mine) + TAPBACK.dropLast(1)
    }

    /**
     * Which slot of a bar a finger at [x] is over: 0 until [optionCount] for
     * the emoji, [optionCount] for the "+". [barLeft] is the bar's left edge,
     * [inset] its padding, [slot] one slot's width.
     */
    fun slotAt(x: Float, barLeft: Float, inset: Float, slot: Float, optionCount: Int): Int =
        ((x - barLeft - inset) / slot).toInt().coerceIn(0, optionCount)
}

/**
 * What the reaction button needs from the app: the account's reactions and a
 * way to send one. Provided once at the root, so every note card's button
 * works without each screen passing it down.
 */
@Stable
class ReactionActions(
    val myReactions: StateFlow<Map<String, EngagementTracker.MyReaction>>,
    val defaultReaction: () -> String,
    /** Sends [emoji] to the note, or takes it back when it is the one already sent. */
    val pick: (noteId: String, emoji: String) -> Unit,
)

val LocalReactionActions = staticCompositionLocalOf<ReactionActions?> { null }

private val SLOT = 44.dp
private val INSET = 6.dp
private const val HOLD_MS = 350L

/**
 * The like button. Tap: react with the default reaction, or take the reaction
 * back ([onTap]). Hold: a bar of emoji above the button, iMessage-style;
 * slide onto one and let go to send it. Let go anywhere else and the bar
 * stays up to be tapped. "+" calls [onMore] (the full picker). The button
 * shows the emoji that was sent.
 */
@Composable
internal fun ReactionButton(
    noteId: String,
    isLiked: Boolean,
    onTap: () -> Unit,
    onMore: (() -> Unit)?,
    /** Likes on a profile post ("64+"); null draws the plain 32dp circle. */
    count: String? = null,
    /** [count] as TalkBack reads it. */
    countDescription: String? = null,
) {
    val actions = LocalReactionActions.current
    val myContent by remember(actions, noteId) {
        actions?.myReactions?.map { it[noteId]?.content }?.distinctUntilChanged()
            ?: kotlinx.coroutines.flow.flowOf(null)
    }.collectAsState(initial = actions?.myReactions?.value?.get(noteId)?.content)
    val shown = ReactionChoice.shown(isLiked, myContent)
    val colors = LocalNostrVaultColors.current
    val haptic = LocalHapticFeedback.current
    val density = LocalDensity.current

    // Bar state. `tracking`: the finger that opened it is still down.
    var barOpen by remember { mutableStateOf(false) }
    var tracking by remember { mutableStateOf(false) }
    var highlighted by remember { mutableStateOf<Int?>(null) }
    var buttonBounds by remember { mutableStateOf(Rect.Zero) }
    var barBounds by remember { mutableStateOf<IntRect?>(null) }
    val options = remember(actions) { ReactionChoice.tapbackOptions(actions?.defaultReaction?.invoke() ?: "+") }
    val slotCount = if (onMore != null) options.size else options.size - 1

    var pulsing by remember { mutableStateOf(false) }
    LaunchedEffect(pulsing) {
        if (pulsing) {
            delay(Motion.PULSE_HOLD_MS)
            pulsing = false
        }
    }
    val scale by animateFloatAsState(if (pulsing) Motion.PULSE_SCALE else 1f, Motion.pop(), label = "reactionPulse")

    fun close() {
        barOpen = false
        tracking = false
        highlighted = null
        barBounds = null
    }
    val choose by rememberUpdatedState { index: Int ->
        close()
        if (index < options.size) {
            if (!Motion.isReduced) pulsing = true
            actions?.pick?.invoke(noteId, options[index])
        } else {
            onMore?.invoke()
        }
    }
    val tap by rememberUpdatedState {
        if (!Motion.isReduced) pulsing = true
        onTap()
    }
    val open by rememberUpdatedState {
        if (actions == null) {
            // Nothing to send from a bar: the picker, as before.
            onMore?.invoke()
        } else {
            barOpen = true
            highlighted = null
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        }
    }
    val track by rememberUpdatedState { point: Offset ->
        val bar = barBounds
        if (bar != null) {
            val barAbove = bar.center.y < buttonBounds.center.y
            val zone = Rect(
                left = bar.left - 8f,
                top = bar.top - if (barAbove) 36f * density.density else 6f * density.density,
                right = bar.right + 8f,
                bottom = bar.bottom + if (barAbove) 6f * density.density else 36f * density.density,
            )
            val index = if (zone.contains(point) && !buttonBounds.contains(point)) {
                ReactionChoice.slotAt(
                    point.x, bar.left.toFloat(), with(density) { INSET.toPx() },
                    with(density) { SLOT.toPx() }, slotCount,
                )
            } else null
            if (index != highlighted) {
                highlighted = index
                if (index != null) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            }
        }
    }

    val label = (shown?.let { "Your reaction: $it" } ?: "React") + (countDescription?.let { ", $it" } ?: "")
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .scale(scale)
            .height(48.dp)
            .onGloballyPositioned { buttonBounds = it.boundsInWindow() }
            .semantics {
                role = Role.Button
                contentDescription = label
                onClick(label = if (shown == null) "React" else "Remove reaction") { tap(); true }
                onLongClick(label = "More reactions") { open(); true }
            }
            .pointerInput(noteId) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val up = try {
                        withTimeout(HOLD_MS) { waitForUpOrCancellation() }
                    } catch (_: PointerEventTimeoutCancellationException) {
                        // Held: open the bar and follow the finger.
                        down.consume()
                        open()
                        if (!barOpen) return@awaitEachGesture
                        tracking = true
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            change.consume()
                            if (!change.pressed) break
                            track(buttonBounds.topLeft + change.position)
                        }
                        tracking = false
                        highlighted?.let { choose(it) }
                        return@awaitEachGesture
                    }
                    if (up != null) {
                        up.consume()
                        tap()
                    }
                }
            }
            .padding(horizontal = 4.dp),
    ) {
        // With a count it becomes a capsule wide enough for the number, as
        // EngagementButton does; the height stays 32dp either way.
        Row(
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .height(32.dp)
                .then(if (count == null) Modifier.width(32.dp) else Modifier.widthIn(min = 32.dp))
                .clip(CircleShape)
                .background(
                    when (shown) {
                        null -> SecondaryText.copy(alpha = 0.10f)
                        "❤️" -> LikeRed.copy(alpha = 0.18f)
                        else -> colors.primary.copy(alpha = 0.18f)
                    },
                )
                .then(if (count == null) Modifier else Modifier.padding(horizontal = 9.dp)),
        ) {
            if (shown != null && shown != "❤️") {
                Text(shown, fontSize = 15.sp)
            } else {
                Icon(
                    imageVector = if (shown == null) NostrVaultIcons.Heart else NostrVaultIcons.HeartFilled,
                    contentDescription = null,
                    tint = if (shown == null) SecondaryText else LikeRed,
                    modifier = Modifier.size(16.dp),
                )
            }
            if (count != null) {
                Spacer(Modifier.width(4.dp))
                Text(
                    text = count,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = if (shown == "❤️") LikeRed else SecondaryText,
                    maxLines = 1,
                )
            }
        }

        if (barOpen) {
            val marginPx = with(density) { 8.dp.roundToPx() }
            val gapPx = with(density) { 12.dp.roundToPx() }
            val minTopPx = with(density) { 100.dp.roundToPx() }
            Popup(
                popupPositionProvider = remember(marginPx, gapPx, minTopPx) {
                    TapbackPosition(marginPx, gapPx, minTopPx) { barBounds = it }
                },
                onDismissRequest = { if (!tracking) close() },
                // Not focusable while the finger is still down: the gesture
                // has to keep reaching the button. After that a tap outside
                // closes it.
                properties = PopupProperties(focusable = !tracking, dismissOnClickOutside = !tracking),
            ) {
                TapbackBar(
                    options = options,
                    current = shown,
                    highlighted = highlighted,
                    showMore = onMore != null,
                    onChoose = { choose(it) },
                )
            }
        }
    }
}

/** Above the button, or below when there is no room; inside the window's sides. */
private class TapbackPosition(
    private val margin: Int,
    private val gap: Int,
    private val minTop: Int,
    private val onPlaced: (IntRect) -> Unit,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val x = (anchorBounds.center.x - popupContentSize.width / 2)
            .coerceAtMost(windowSize.width - popupContentSize.width - margin)
            .coerceAtLeast(margin)
        val above = anchorBounds.top - gap - popupContentSize.height
        val y = if (above >= minTop) above else anchorBounds.bottom + gap
        onPlaced(IntRect(IntOffset(x, y), popupContentSize))
        return IntOffset(x, y)
    }
}

@Composable
private fun TapbackBar(
    options: List<String>,
    current: String?,
    highlighted: Int?,
    showMore: Boolean,
    onChoose: (Int) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    val appear by animateFloatAsState(if (shown) 1f else 0f, Motion.pop(), label = "tapbackAppear")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .graphicsLayer {
                val s = 0.5f + 0.5f * appear
                scaleX = s
                scaleY = s
                alpha = appear.coerceIn(0f, 1f)
            }
            .shadow(14.dp, CircleShape)
            .clip(CircleShape)
            .background(Color(0xFF2B2B2B))
            .border(0.5.dp, Color.White.copy(alpha = 0.1f), CircleShape)
            .padding(INSET),
    ) {
        options.forEachIndexed { index, emoji ->
            val lift by animateFloatAsState(if (highlighted == index) 1f else 0f, Motion.pop(), label = "tapbackLift")
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(SLOT)
                    .semantics { contentDescription = if (emoji == current) "$emoji, your reaction" else emoji }
                    .clickable { onChoose(index) },
            ) {
                if (emoji == current) {
                    Box(Modifier.size(SLOT).clip(CircleShape).background(colors.primary.copy(alpha = 0.3f)))
                }
                Text(
                    emoji,
                    fontSize = 26.sp,
                    modifier = Modifier.graphicsLayer {
                        val s = 1f + 0.45f * lift
                        scaleX = s
                        scaleY = s
                        translationY = -10.dp.toPx() * lift
                    },
                )
            }
        }
        if (showMore) {
            val lift by animateFloatAsState(if (highlighted == options.size) 1f else 0f, Motion.pop(), label = "tapbackMore")
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(SLOT)
                    .semantics { contentDescription = "More reactions" }
                    .clickable { onChoose(options.size) },
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(34.dp)
                        .graphicsLayer {
                            val s = 1f + 0.3f * lift
                            scaleX = s
                            scaleY = s
                        }
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.12f)),
                ) {
                    Icon(
                        NostrVaultIcons.Create,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.8f),
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}
