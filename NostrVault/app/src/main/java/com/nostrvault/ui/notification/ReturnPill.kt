package com.nostrvault.ui.notification

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.nostrvault.service.ReturnPillManager
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Where the Vault tab is on screen, in root coordinates, for the return
 * pill's arrow. Null while the tab bar is folded or gone. iOS `VaultAnchor`.
 */
object VaultAnchor {
    private val _frame = MutableStateFlow<Rect?>(null)
    val frame: StateFlow<Rect?> = _frame.asStateFlow()

    internal fun set(frame: Rect?) {
        // Zero-size while the tab is still being laid out.
        _frame.value = frame?.takeIf { it.width > 0f && it.height > 0f }
    }
}

/** Marks this as the Vault tab the return pill points at. */
@Composable
fun Modifier.vaultAnchor(): Modifier {
    DisposableEffect(Unit) { onDispose { VaultAnchor.set(null) } }
    return onGloballyPositioned { VaultAnchor.set(it.boundsInRoot()) }
}

private val ArrowLength = 8.dp
private val ArrowWidth = 16.dp
/** Above the tab bar (and the mini player), and the gap a lifted floating button leaves above the pill. */
private val Gap = 8.dp
/** The tab bar's clear space above its pill: the arrow's tip sits [Gap] above the pill, not the padding. */
private val BarTopPadding = 12.dp

/**
 * What came in while the app was away, as one pill at the bottom (iOS
 * `ReturnPillLayer`): "5 mentions · 2 zaps · 1 DM", just above the tab bar
 * (and the mini player), over the Vault tab with its arrow pointing down at
 * it. The screen's floating button (Post) rises clear of it while it shows
 * and settles back as it goes. With no Vault tab on screen it sits at the
 * bottom centre with no arrow. A tap opens the Vault on its "Vault" list.
 * [ReturnPillManager] decides when it shows. Fills the screen; only the pill
 * takes touches.
 */
@Composable
fun ReturnPill(modifier: Modifier = Modifier) {
    val showing by ReturnPillManager.isShowing.collectAsState()
    val text by ReturnPillManager.text.collectAsState()
    val spoken by ReturnPillManager.spoken.collectAsState()
    val anchor by VaultAnchor.frame.collectAsState()
    val track by MusicPlayer.current.collectAsState()
    val visible = showing && text.isNotEmpty()
    val density = LocalDensity.current

    // The arrow's tip above the screen's bottom: over the tab bar's pill, or
    // over the mini player when one is up (iOS bottomInset).
    val tipAbove = if (track != null) {
        FloatingButtonRow.rowBottom + FloatingButtonRow.miniPlayerHeight + Gap
    } else {
        FloatingButtonRow.rowBottom - FloatingButtonRow.aboveBar + Gap
    }
    var origin by remember { mutableStateOf(Offset.Zero) }
    var pillHeight by remember { mutableIntStateOf(0) }

    // Lift the floating button clear of the pill while it shows (iOS liftButtons).
    LaunchedEffect(visible, pillHeight, tipAbove) {
        FloatingButtonRow.lift = if (visible && pillHeight > 0) {
            val pillTop = tipAbove + with(density) { pillHeight.toDp() }
            (pillTop + Gap - FloatingButtonRow.rowBottom).coerceAtLeast(0.dp)
        } else {
            0.dp
        }
    }
    DisposableEffect(Unit) { onDispose { FloatingButtonRow.lift = 0.dp } }

    Layout(
        modifier = modifier
            .fillMaxSize()
            .onGloballyPositioned { origin = it.positionInRoot() },
        content = {
            AnimatedVisibility(
                visible = visible,
                enter = slideInVertically { it } + fadeIn(),
                exit = slideOutVertically { it } + fadeOut(),
            ) {
                ReturnPillCapsule(text, spoken, arrowAt = anchor?.center?.x)
            }
        },
    ) { measurables, constraints ->
        val margin = PillStyle.sideMargin.roundToPx()
        val pill = measurables.firstOrNull()?.measure(
            Constraints(maxWidth = (constraints.maxWidth - 2 * margin).coerceAtLeast(0)),
        )
        pillHeight = pill?.height ?: 0
        layout(constraints.maxWidth, constraints.maxHeight) {
            pill ?: return@layout
            val w = pill.width
            val target = anchor?.center?.x?.minus(origin.x)?.toInt()
            val x = if (target == null) {
                (constraints.maxWidth - w) / 2
            } else {
                // Over the Vault tab as far as the screen's edge allows; the arrow stays on the tab.
                (target - w / 2).coerceIn(margin, (constraints.maxWidth - w - margin).coerceAtLeast(margin))
            }
            val y = constraints.maxHeight - tipAbove.roundToPx() - pill.height
            pill.place(x, y)
        }
    }
}

/**
 * The accent capsule and, when [arrowAt] is known, its arrow: one shape, so
 * the shadow and the tap cover both. [arrowAt] is the Vault tab's centre in
 * root coordinates; the shape gets it relative to the pill's left edge.
 */
@Composable
private fun ReturnPillCapsule(text: String, spoken: String, arrowAt: Float?) {
    var left by remember { mutableStateOf(0f) }
    val shape = remember(arrowAt, left) { ReturnPillShape(arrowAt?.minus(left)) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .onGloballyPositioned { left = it.positionInRoot().x }
            .shadow(8.dp, shape, ambientColor = ShadowColor, spotColor = ShadowColor)
            .background(PillTone.ACCENT.color(), shape)
            .clip(shape)
            .clickable(onClick = ReturnPillManager::open)
            .padding(bottom = if (arrowAt != null) ArrowLength else 0.dp)
            .padding(vertical = PillSize.REGULAR.vertical, horizontal = PillSize.REGULAR.horizontal)
            .semantics(mergeDescendants = true) {
                role = Role.Button
                contentDescription = "While you were away: $spoken. Opens the Vault."
            },
    ) {
        PillIcon(NostrVaultIcons.TabVault)
        PillText(text)
    }
}

private val ShadowColor = Color.Black.copy(alpha = 0.4f)

/**
 * A capsule with a small triangle hanging from its bottom edge at [arrowAt]
 * (px from the pill's left), kept on the straight part of the capsule. The
 * arrow is inside the bounds: the capsule is the top part, the arrow the
 * bottom [ArrowLength]. No arrow when [arrowAt] is null.
 */
private class ReturnPillShape(private val arrowAt: Float?) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        if (arrowAt == null) {
            return Outline.Rounded(RoundRect(0f, 0f, size.width, size.height, CornerRadius(size.height / 2)))
        }
        val arrow = with(density) { ArrowLength.toPx() }
        val half = with(density) { ArrowWidth.toPx() } / 2
        val h = size.height - arrow
        val radius = h / 2
        val along = arrowAt.coerceIn(radius, (size.width - radius).coerceAtLeast(radius))
        val path = Path().apply {
            addRoundRect(RoundRect(0f, 0f, size.width, h, CornerRadius(radius)))
            moveTo(along - half, h - 1f)
            lineTo(along + half, h - 1f)
            lineTo(along, size.height)
            close()
        }
        return Outline.Generic(path)
    }
}
