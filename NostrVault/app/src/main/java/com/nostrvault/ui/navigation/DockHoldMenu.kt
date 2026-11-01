package com.nostrvault.ui.navigation

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.glassRectBackground
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalOledMode
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import kotlin.math.PI
import kotlin.math.roundToInt

/**
 * Press a dock button and either hold a moment or slide a little: the menu
 * opens, the highlight follows the finger at once, and letting go on a row
 * picks it. Let go anywhere else (in place on the button, or off the menu)
 * and it cancels. A plain tap is still the button. One engine for the Feed
 * tab (feeds), the Vault tab (its pages) and the account picture (accounts).
 * iOS: HavenApp-iOS/Shell/DockHoldMenu.swift (#1505); the iPhone look is the
 * reference.
 *
 * The finger never leaves the button's own gesture, so the menu does not take
 * touches while dragging: the button hit-tests the finger against the rows'
 * bounds itself, all in root coordinates. The menu lines up with the side of
 * the screen its button is on.
 */
@Stable
class DockHoldMenu<T> {
    var isOpen by mutableStateOf(false)
        private set
    /** The finger is down on the tab (it shrinks while pressed). */
    var isPressed by mutableStateOf(false)
        internal set
    var hovered by mutableStateOf<T?>(null)
        internal set
    /** The tab's bounds, root coordinates; the menu rises from them. */
    var anchor by mutableStateOf(Rect.Zero)
        private set
    /** Each row's bounds, root coordinates. */
    internal val rowBounds = mutableStateMapOf<T, Rect>()
    /** The rows the menu lists now; a row gone since it was laid out keeps stale bounds. */
    internal var listed: List<T> = emptyList()

    fun itemAt(point: Offset, slackXPx: Float, slackYPx: Float): T? {
        val shown = listed.toSet()
        return dockRowAt(rowBounds.filterKeys { it in shown }, point, slackXPx, slackYPx)
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

/** The numbers PR #1505 set on iOS, in Android units. */
object DockHold {
    /** Hold before the menu opens: a tap lifts sooner; anything longer is a hold (Logen 11-01). */
    const val HOLD_MS = 100L
    /** A slide this far while pressed opens the menu at once, without waiting for the hold. */
    val OPEN_SLIDE = 6.dp
    /** Row hit area: the row plus this either side, and 1 dp up and down. */
    val ROW_SLACK_X = 28.dp
    val ROW_SLACK_Y = 1.dp
    /** Tab scale while pressed, and while its menu is open. */
    const val PRESSED_SCALE = 0.94f
    const val OPEN_SCALE = 1.08f

    /** A SwiftUI spring(response:dampingFraction:) as a Compose spring. */
    fun <T> swiftSpring(response: Float, damping: Float) =
        spring<T>(dampingRatio = damping, stiffness = (2 * PI / response).let { (it * it).toFloat() })

    /** Haptics: light on open, a tick per row crossed, light on pick, none on cancel. */
    enum class Haptic { OPEN, ROW, PICK }

    /** The platform constant for [h] on API [sdk]. */
    fun constant(h: Haptic, sdk: Int = Build.VERSION.SDK_INT): Int = when (h) {
        Haptic.OPEN -> HapticFeedbackConstants.CONTEXT_CLICK
        Haptic.ROW -> if (sdk >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK
        Haptic.PICK -> if (sdk >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.CONTEXT_CLICK
    }

    fun perform(view: View, h: Haptic) {
        view.performHapticFeedback(constant(h))
    }

    /** What a touch became before the hold landed. */
    enum class Early { TAP, OPEN }

    /**
     * A slide of [openPx] opens the menu straight away; letting go before
     * that, and before the hold, is a tap. Null: still waiting.
     */
    fun early(released: Boolean, movedPx: Float, openPx: Float): Early? = when {
        movedPx >= openPx -> Early.OPEN
        released -> Early.TAP
        else -> null
    }
}

/** The row under [point], with the row's hit area widened by the slack. */
internal fun <T> dockRowAt(rows: Map<T, Rect>, point: Offset, slackXPx: Float, slackYPx: Float): T? =
    rows.entries.firstOrNull { (_, r) ->
        point.y >= r.top - slackYPx && point.y < r.bottom + slackYPx &&
            point.x >= r.left - slackXPx && point.x < r.right + slackXPx
    }?.key

/**
 * The tab's gesture: tap → [onTap]; hold [DockHold.HOLD_MS] → the menu
 * opens, the highlight follows the finger, and letting go over a row picks
 * it. Letting go anywhere else cancels. [coordinates] are this node's.
 */
internal fun <T> Modifier.dockHold(
    menu: DockHoldMenu<T>,
    coordinates: () -> LayoutCoordinates?,
    view: View,
    onTap: () -> Unit,
    onPick: (T) -> Unit,
): Modifier = pointerInput(menu) {
    val openPx = DockHold.OPEN_SLIDE.toPx()
    val slackX = DockHold.ROW_SLACK_X.toPx()
    val slackY = DockHold.ROW_SLACK_Y.toPx()
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        fun toRoot(p: Offset): Offset = coordinates()?.let { c -> c.localToRoot(p) } ?: p

        if (menu.isOpen) {
            // Left open somehow (the window lost the finger): a touch closes it.
            do {
                val ev = awaitPointerEvent()
                ev.changes.forEach { it.consume() }
            } while (ev.changes.any { it.pressed })
            menu.close()
            return@awaitEachGesture
        }

        menu.isPressed = true
        var early: DockHold.Early? = null
        var at = down.position
        withTimeoutOrNull(DockHold.HOLD_MS) {
            while (early == null) {
                val ev = awaitPointerEvent()
                val change = ev.changes.firstOrNull { it.id == down.id }
                val released = change == null || !change.pressed
                change?.let { at = it.position }
                early = DockHold.early(released, (at - down.position).getDistance(), openPx)
            }
        }
        menu.isPressed = false
        if (early == DockHold.Early.TAP) {
            onTap()
            return@awaitEachGesture
        }

        // Held, or slid: open, and track the finger from this frame on.
        DockHold.perform(view, DockHold.Haptic.OPEN)
        menu.open(coordinates()?.boundsInRoot() ?: Rect.Zero)
        var last = toRoot(at)
        while (true) {
            val ev = awaitPointerEvent()
            val change = ev.changes.firstOrNull { it.id == down.id } ?: break
            change.consume()
            last = toRoot(change.position)
            if (!change.pressed) break
            val row = menu.itemAt(last, slackX, slackY)
            if (row != menu.hovered) {
                menu.hovered = row
                if (row != null) DockHold.perform(view, DockHold.Haptic.ROW)
            }
        }
        val picked = menu.itemAt(last, slackX, slackY)
        menu.close()
        if (picked != null) {
            DockHold.perform(view, DockHold.Haptic.PICK)
            onPick(picked)
        }
    }
}

/**
 * One menu row: its icon (or an account's picture), name, whether it is what
 * shows now, and a red dot on the icon when it has something new.
 */
data class DockHoldRow(
    val icon: ImageVector?,
    val label: String,
    val current: Boolean,
    val hasNews: Boolean = false,
    /** An account row: its pubkey and picture, drawn in place of [icon]. */
    val avatar: Pair<String, String?>? = null,
)

/**
 * The menu itself, drawn over the whole window above the bar, growing up
 * from its tab's side of the screen with the first entry right above the
 * finger. A tap on the dim behind it closes it.
 */
@Composable
fun <T> DockHoldMenuOverlay(
    menu: DockHoldMenu<T>,
    /** In the reader's order; drawn bottom-up, so the first sits above the tab. */
    items: List<T>,
    row: (T) -> DockHoldRow,
    closeLabel: String,
    onPick: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val open = menu.isOpen
    val density = LocalDensity.current
    SideEffect { menu.listed = items }
    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        AnimatedVisibility(visible = open, enter = fadeIn(tween(140)), exit = fadeOut(tween(140))) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.28f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClickLabel = closeLabel,
                    ) { menu.close() },
            )
        }
        var rootOrigin by remember { mutableStateOf(Offset.Zero) }
        val anchor = menu.anchor
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        val marginPx = with(density) { 12.dp.toPx() }
        val bottomPx = maxOf(marginPx, heightPx - (anchor.top - rootOrigin.y) + with(density) { 10.dp.toPx() })
        // The side of the screen the button is on (iOS: anchor.midX > midX).
        val trailing = anchor.center.x - rootOrigin.x > widthPx / 2
        val sidePx = if (trailing) {
            maxOf(marginPx, widthPx - (anchor.right - rootOrigin.x))
        } else {
            maxOf(marginPx, anchor.left - rootOrigin.x)
        }
        val origin = TransformOrigin(if (trailing) 1f else 0f, 1f)
        Box(
            Modifier
                .fillMaxSize()
                .onGloballyPositioned { rootOrigin = it.boundsInRoot().topLeft },
        ) {
            AnimatedVisibility(
                visible = open,
                enter = fadeIn(DockHold.swiftSpring(0.22f, 0.84f)) +
                    scaleIn(DockHold.swiftSpring(0.22f, 0.84f), initialScale = 0.6f, transformOrigin = origin),
                exit = fadeOut(tween(140)) + scaleOut(tween(140), targetScale = 0.6f, transformOrigin = origin),
                modifier = Modifier
                    .align(if (trailing) Alignment.BottomEnd else Alignment.BottomStart)
                    .offset { IntOffset(if (trailing) -sidePx.roundToInt() else sidePx.roundToInt(), -bottomPx.roundToInt()) },
            ) {
                // iOS: applyGlassRect(cornerRadius: 22) + shadow(.black 0.35, radius 18, y 6).
                Column(
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier
                        .shadow(18.dp, RoundedCornerShape(22.dp), ambientColor = Color.Black.copy(alpha = 0.35f), spotColor = Color.Black.copy(alpha = 0.35f))
                        .glassRectBackground(cornerRadius = 22.dp, isOled = LocalOledMode.current)
                        .padding(6.dp),
                ) {
                    for (item in items.reversed()) {
                        DockHoldMenuRow(
                            spec = row(item),
                            hovered = menu.hovered == item,
                            onPlaced = { menu.rowBounds[item] = it },
                            onClick = {
                                menu.close()
                                onPick(item)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DockHoldMenuRow(
    spec: DockHoldRow,
    hovered: Boolean,
    onPlaced: (Rect) -> Unit,
    onClick: () -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    val scale by animateFloatAsState(
        if (hovered) 1.04f else 1f,
        animationSpec = DockHold.swiftSpring(0.16f, 0.7f),
        label = "dockRowScale",
    )
    val tint = when {
        hovered -> Color.White
        spec.current -> accent
        else -> PrimaryText
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .onGloballyPositioned { onPlaced(it.boundsInRoot()) }
            .scale(scale)
            .width(210.dp)
            .height(42.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (hovered) accent else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp)
            .semantics(mergeDescendants = true) { if (spec.hasNews) stateDescription = "New activity" },
    ) {
        // The icon in a 24 dp frame, the red dot on its top-right corner (iOS).
        Box(Modifier.width(24.dp), contentAlignment = Alignment.Center) {
            val avatar = spec.avatar
            if (avatar != null) {
                AvatarImage(url = avatar.second, pubkey = avatar.first, size = 24.dp, displayName = spec.label)
            } else if (spec.icon != null) {
                Icon(spec.icon, contentDescription = null, tint = tint, modifier = Modifier.size(19.dp))
            }
            if (spec.hasNews) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 2.dp, y = (-2).dp)
                        .size(8.dp)
                        .background(ErrorRed, CircleShape),
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        Text(
            text = spec.label,
            color = tint,
            fontSize = 16.sp,
            fontWeight = if (spec.current) FontWeight.Bold else FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (spec.current) {
            Spacer(Modifier.width(16.dp))
            Icon(NostrVaultIcons.Check, contentDescription = "Showing now", tint = tint, modifier = Modifier.size(13.dp))
        }
    }
}
