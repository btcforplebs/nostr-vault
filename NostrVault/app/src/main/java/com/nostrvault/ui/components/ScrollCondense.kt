package com.nostrvault.ui.components

import androidx.compose.animation.core.animate
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.offset
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * How far the scroll-driven chrome — the bottom bar, the feed's top bar and
 * the per-tab FABs — has folded away: 0 fully shown, 1 fully folded.
 *
 * The bars follow the finger: a drag moves [progress] by the distance the
 * list actually scrolled, over [TravelDp], so a half drag leaves them half
 * folded. On release they settle to the nearer end, or the end the fling was
 * heading for, on the `chrome` spring. Only gestures move them — a list
 * scrolled by code (new notes at the top, a restored position, scroll to top)
 * never does, because those scrolls don't pass through nested scroll.
 *
 * Read [progress] inside layout or draw lambdas (`Modifier.layout`,
 * `graphicsLayer {}`), never in composition: it changes every frame of a
 * drag, and reading it there would recompose the reader every frame.
 *
 * iOS parity: FeedView's ScrollDirectionModifier + ContentView's tab bar.
 */
object ScrollChrome {
    /** Scroll distance that takes the chrome from shown to folded. */
    val TravelDp = 64.dp

    /** A fling faster than this (px/s) decides the settle direction by itself. */
    private const val FLING_DECIDES = 600f

    var progress by mutableFloatStateOf(0f)
        private set

    /**
     * The visible list's distance from its very top in px, or null when its
     * first item is off screen. Reported by [ScrollCondenseEffect].
     */
    private var topDistancePx by mutableStateOf<Int?>(null)

    private var settleJob: Job? = null

    /**
     * Opacity of what folds away: gone by 60% of the fold. iOS
     * `ChromeCollapse.fadeOut`.
     */
    fun fadeOut(p: Float): Float = (1f - p / 0.6f).coerceIn(0f, 1f)

    /**
     * Opacity of what the fold reveals: starts at 40%, so outgoing and
     * incoming controls never read as stacked. iOS `ChromeCollapse.fadeIn`.
     */
    fun fadeIn(p: Float): Float = ((p - 0.4f) / 0.6f).coerceIn(0f, 1f)

    /** Folded past halfway — which controls take taps, and the old boolean. */
    val isFolded: Boolean get() = progress > 0.5f

    /** Near the top the chrome is always shown: progress is capped by the distance left. */
    private fun topCap(travelPx: Float): Float? = topDistancePx?.let { it / travelPx }

    internal fun drag(deltaPx: Float, travelPx: Float) {
        settleJob?.cancel()
        var p = (progress + deltaPx / travelPx).coerceIn(0f, 1f)
        topCap(travelPx)?.let { p = minOf(p, it) }
        progress = p
    }

    internal fun settle(scope: CoroutineScope, velocityY: Float, travelPx: Float) {
        animateTo(scope, settleTarget(progress, velocityY, topCap(travelPx)))
    }

    /**
     * Where a released fold comes to rest: shown near the top; otherwise the
     * way a decided fling was heading; otherwise the nearer end.
     */
    internal fun settleTarget(progress: Float, velocityY: Float, topCap: Float?): Float = when {
        topCap != null && topCap < 1f -> 0f
        // Velocity is in finger direction: up (negative) scrolls the feed down.
        velocityY < -FLING_DECIDES -> 1f
        velocityY > FLING_DECIDES -> 0f
        else -> if (progress > 0.5f) 1f else 0f
    }

    /** Shows the chrome, e.g. a tap on the folded bar's avatar. */
    fun expand(scope: CoroutineScope) = animateTo(scope, 0f)

    /** Snaps back to shown: the scrolled screen is gone, or folding was switched off. */
    fun reset() {
        settleJob?.cancel()
        progress = 0f
        topDistancePx = null
    }

    private fun animateTo(scope: CoroutineScope, target: Float) {
        settleJob?.cancel()
        if (progress == target) return
        settleJob = scope.launch {
            animate(progress, target, animationSpec = Motion.chrome()) { value, _ -> progress = value }
        }
    }

    internal fun reportTop(index: Int, offsetPx: Int, travelPx: Float, scope: CoroutineScope?) {
        topDistancePx = if (index == 0) offsetPx else null
        if (scope == null) return
        // Arrived at the top without a gesture (a reselect's scroll to top):
        // bring the chrome back rather than leave it folded over the feed's head.
        val cap = topCap(travelPx)
        if (cap != null && cap < progress && settleJob?.isActive != true) animateTo(scope, 0f)
    }
}

/**
 * Feeds every vertical drag and fling of the screen below into
 * [ScrollChrome]. Attach once, above the scrollable tabs. [enabled] false
 * (a tab without folding, or "disable tab bar animation") leaves the chrome
 * shown.
 */
@Composable
fun rememberScrollChromeConnection(enabled: Boolean): NestedScrollConnection {
    val scope = rememberCoroutineScope()
    val travelPx = with(LocalDensity.current) { ScrollChrome.TravelDp.toPx() }
    val isEnabled by rememberUpdatedState(enabled)
    LaunchedEffect(enabled) { if (!enabled) ScrollChrome.reset() }
    return remember(scope, travelPx) {
        object : NestedScrollConnection {
            private var releaseVelocity = 0f

            // What the list actually consumed, not what was offered: an
            // overscroll at either end moves nothing, so the bounce at the
            // bottom of the feed can't pop the bars back.
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (isEnabled && consumed.y != 0f) ScrollChrome.drag(-consumed.y, travelPx)
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                releaseVelocity = available.y
                return Velocity.Zero
            }

            // Runs after every release, a slow one included (its fling is zero).
            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                if (isEnabled) ScrollChrome.settle(scope, releaseVelocity, travelPx)
                return Velocity.Zero
            }
        }
    }
}

/**
 * Tells [ScrollChrome] where the visible list is relative to its top, so the
 * chrome is always shown near it. Resets the chrome when the host leaves
 * composition (a tab switch).
 *
 * Works for both LazyListState and LazyGridState — pass their
 * firstVisibleItemIndex / firstVisibleItemScrollOffset as lambdas.
 *
 * @param scrollKey re-arms the snapshot loop when the underlying scroll source
 *   changes (e.g. the media grid/list toggle swaps which state is observed).
 */
@Composable
fun ScrollCondenseEffect(
    scrollKey: Any?,
    firstVisibleItemIndex: () -> Int,
    firstVisibleItemScrollOffset: () -> Int,
) {
    val scope = rememberCoroutineScope()
    val travelPx = with(LocalDensity.current) { ScrollChrome.TravelDp.toPx() }
    LaunchedEffect(scrollKey, travelPx) {
        snapshotFlow { firstVisibleItemIndex() to firstVisibleItemScrollOffset() }
            .collect { (index, offset) -> ScrollChrome.reportTop(index, offset, travelPx, scope) }
    }
    DisposableEffect(Unit) {
        onDispose { ScrollChrome.reset() }
    }
}

/**
 * Folds a piece of chrome away with [ScrollChrome]: its width shrinks to
 * nothing and it fades out a little ahead of that. Layout-phase only, so a
 * drag re-lays-out the bar without recomposing it.
 *
 * [leadingGap] is the space between this piece and the one it folds into.
 * It folds away with the piece, so a pill left with one button closes into
 * a circle around it instead of keeping the gap as a stub.
 */
fun Modifier.chromeFold(leadingGap: Dp = 0.dp): Modifier = this
    .clipToBounds()
    .layout { measurable, constraints ->
        val gap = leadingGap.roundToPx()
        val placeable = measurable.measure(constraints.offset(horizontal = -gap))
        val p = ScrollChrome.progress
        layout(((placeable.width + gap) * (1f - p)).roundToInt(), placeable.height) {
            placeable.placeRelativeWithLayer(gap, 0) { alpha = (1f - p * 1.6f).coerceAtLeast(0f) }
        }
    }

/**
 * A FAB that folds with the chrome: it shrinks into its corner and fades as
 * the bars fold, the way the iPhone's Post button does.
 */
fun Modifier.chromeFab(): Modifier = this.layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    val p = ScrollChrome.progress
    val fabAlpha = (1f - p * 1.4f).coerceAtLeast(0f)
    layout(placeable.width, placeable.height) {
        // Faded out entirely: not placed, so it takes no taps meant for the feed.
        if (fabAlpha > 0f) placeable.placeRelativeWithLayer(0, 0) {
            alpha = fabAlpha
            transformOrigin = TransformOrigin(1f, 1f)
            scaleX = 1f - 0.5f * p
            scaleY = 1f - 0.5f * p
        }
    }
}

/**
 * The floating "New Posts" button's fold: it fades, shrinks toward its top
 * edge and rises [rise] back under the top bar as the bars fold, and returns
 * with them. Folded, a small pill in the top bar's row stands in for it
 * ([chromeReveal]). iOS `NewPostsFold`.
 */
fun Modifier.newPostsFold(rise: Dp = 16.dp): Modifier = this.layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    val visible = ScrollChrome.fadeOut(ScrollChrome.progress)
    val risePx = rise.toPx()
    layout(placeable.width, placeable.height) {
        // Faded out entirely: not placed, so it takes no taps meant for the feed.
        if (visible > 0f) placeable.placeRelativeWithLayer(0, 0) {
            alpha = visible
            transformOrigin = TransformOrigin(0.5f, 0f)
            scaleX = 0.85f + 0.15f * visible
            scaleY = 0.85f + 0.15f * visible
            translationY = -risePx * (1f - visible)
        }
    }
}

/**
 * The opposite of a fold: content that appears as the bars fold (the small
 * "New Posts" pill in the folded top bar). iOS `ChromeFold(inverted: true)`.
 */
fun Modifier.chromeReveal(): Modifier = this.layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    val visible = ScrollChrome.fadeIn(ScrollChrome.progress)
    layout(placeable.width, placeable.height) {
        if (visible > 0f) placeable.placeRelativeWithLayer(0, 0) {
            alpha = visible
            scaleX = 0.85f + 0.15f * visible
            scaleY = 0.85f + 0.15f * visible
        }
    }
}

/**
 * Swallows touches and hides from accessibility while [blocked]: folded
 * chrome is still composed (it has to be, to fold smoothly) and must not
 * take taps meant for what is drawn over or around it.
 */
fun Modifier.blockedWhen(blocked: Boolean): Modifier =
    if (!blocked) this
    else this
        .clearAndSetSemantics { }
        .pointerInput(Unit) {
            awaitPointerEventScope {
                while (true) {
                    awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                }
            }
        }

/**
 * [ScrollChrome.isFolded] as state that changes only when it flips — safe to
 * read in composition, unlike [ScrollChrome.progress].
 */
@Composable
fun rememberChromeFolded(): State<Boolean> = remember { derivedStateOf { ScrollChrome.isFolded } }
