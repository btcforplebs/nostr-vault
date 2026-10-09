package com.nostrvault.tutorials

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * Draws the active tutorial's card, pointing at its anchor (iOS
 * `TutorialStage`). It sits over the live app and never dims or blocks it:
 * only the card takes touches. The app's own stage lives in MainActivity's
 * root box, above the nav host, so it stays over every screen. A sheet with
 * anchors in it draws its own, with its own [layer] (see
 * [LocalTutorialLayer]): a card goes on the stage its anchor is in.
 *
 * A card that points at something waits until that thing is on screen:
 * replayed from Settings, the feed is still coming back into view. If it
 * isn't there after [ANCHOR_WAIT_MS] (an empty activity log, say), the card
 * shows anyway with no pointer, on the top stage, so a tutorial can never
 * sit on screen with nothing to see or skip.
 */
@Composable
fun TutorialStage(
    account: () -> String,
    modifier: Modifier = Modifier,
    layer: String = ROOT_TUTORIAL_LAYER,
) {
    DisposableEffect(layer) {
        TutorialCenter.layers.add(layer)
        onDispose { TutorialCenter.layers.remove(layer) }
    }
    val active by TutorialCenter.active.collectAsState()
    val stepIndex by TutorialCenter.stepIndex.collectAsState()
    val id = active ?: return
    val step = id.steps.getOrNull(stepIndex) ?: return
    val placed = step.anchor?.let { TutorialCenter.anchors[it] }
    var waitedForAnchor by remember(id, stepIndex) { mutableStateOf(false) }
    LaunchedEffect(id, stepIndex) {
        delay(ANCHOR_WAIT_MS)
        waitedForAnchor = true
    }
    val drawsHere = if (placed != null) {
        placed.layer == layer
    } else {
        (step.anchor == null || waitedForAnchor) && TutorialCenter.layers.lastOrNull() == layer
    }
    if (!drawsHere) return

    val density = LocalDensity.current
    val primary = LocalNostrVaultColors.current.primary
    // Unknown until the stage is laid out; a sheet's stage isn't at the
    // window's origin, so nothing is drawn until it's known.
    var rootOrigin by remember { mutableStateOf<Offset?>(null) }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .onGloballyPositioned { rootOrigin = it.positionInRoot() },
    ) {
        val origin = rootOrigin ?: return@BoxWithConstraints
        val local = placed?.bounds?.translate(-origin)
        val placement = with(density) {
            TutorialCardPlacement(
                anchor = local,
                width = maxWidth.toPx(),
                height = maxHeight.toPx(),
                metrics = TutorialCardPlacement.Metrics.from(this),
            )
        }

        if (local != null) {
            val pad = with(density) { RING_OUTSET.toPx() }
            Box(
                Modifier
                    .offset { IntOffset((local.left - pad).roundToInt(), (local.top - pad).roundToInt()) }
                    .size(
                        with(density) { (local.width + 2 * pad).toDp() },
                        with(density) { (local.height + 2 * pad).toDp() },
                    )
                    .border(3.dp, primary, RoundedCornerShape(50)),
            )
        }

        Box(
            Modifier
                .width(with(density) { placement.cardWidth.toDp() })
                // Placed by its edge, from its real height, so it can't cover
                // what it points at.
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints)
                    layout(placeable.width, placeable.height) {
                        placeable.place(
                            placement.x.roundToInt(),
                            placement.y(placeable.height.toFloat()).roundToInt(),
                        )
                    }
                },
        ) {
            AnimatedContent(
                targetState = stepIndex,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "tutorialCard",
            ) { index ->
                val shown = id.steps.getOrNull(index) ?: return@AnimatedContent
                val isLast = index >= id.steps.size - 1
                val next = if (isLast) TutorialCenter.nextAfter(id) else null
                TutorialCard(
                    position = "${index + 1} of ${id.steps.size}",
                    step = shown,
                    tail = placement.tail,
                    canGoBack = index > 0,
                    nextLabel = when {
                        next != null -> "Next: ${next.title}"
                        isLast -> "Done"
                        else -> "Next"
                    },
                    onSkip = { TutorialCenter.skip(id, account()) },
                    onBack = { TutorialCenter.back() },
                    onNext = {
                        if (next != null) TutorialCenter.startNext(account()) else TutorialCenter.next(account())
                    },
                )
            }
        }
    }
}

/** How long a card waits for its anchor before showing without a pointer. */
private const val ANCHOR_WAIT_MS = 1_500L

/** The ring's outset from its anchor. */
private val RING_OUTSET = 6.dp

@Composable
private fun TutorialCard(
    position: String,
    step: TutorialStep,
    tail: TutorialCardPlacement.Tail?,
    canGoBack: Boolean,
    nextLabel: String,
    onSkip: () -> Unit,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    val primary = LocalNostrVaultColors.current.primary
    val shape = TutorialCardShape(tail)
    val tailHeight = TutorialCardPlacement.TAIL_HEIGHT
    Column(
        Modifier
            .fillMaxWidth()
            .shadow(16.dp, shape)
            .background(Color(0xFF1F1F1F), shape)
            .border(1.dp, primary.copy(alpha = 0.6f), shape)
            // The tail sits inside the card's bounds, on the edge facing the anchor.
            .padding(
                top = if (tail?.edge == TutorialCardPlacement.TailEdge.TOP) tailHeight else 0.dp,
                bottom = if (tail?.edge == TutorialCardPlacement.TailEdge.BOTTOM) tailHeight else 0.dp,
            )
            .padding(16.dp)
            .semantics { paneTitle = "Tutorial" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(position, color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onSkip) {
                Text("Skip", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Text(step.title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(step.body, color = PrimaryText.copy(alpha = 0.85f), fontSize = 15.sp)
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            if (canGoBack) {
                TextButton(onClick = onBack) { Text("Back", color = PrimaryText.copy(alpha = 0.85f)) }
            }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onNext,
                colors = ButtonDefaults.buttonColors(containerColor = primary, contentColor = Color.White),
            ) {
                Text(nextLabel, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/**
 * Where a card sits and where its tail points (iOS
 * `TutorialCardPlacement`). Below the anchor when the anchor is in the top
 * half of the screen, above it otherwise, kept on screen; the tail sits on
 * the edge facing the anchor, under its middle. With no anchor: low and
 * centred, no tail. All in pixels.
 */
class TutorialCardPlacement(anchor: Rect?, width: Float, height: Float, metrics: Metrics) {
    enum class TailEdge { TOP, BOTTOM }

    /** [x] is the tip's, from the card's left edge. */
    data class Tail(val edge: TailEdge, val x: Float)

    /** The sizes below, in pixels. */
    data class Metrics(
        val maxWidth: Float,
        val margin: Float,
        val ringGap: Float,
        val tailHalfWidth: Float,
        val cornerRadius: Float,
        val noAnchorBottom: Float,
    ) {
        companion object {
            fun from(density: Density) = with(density) {
                Metrics(
                    maxWidth = 340.dp.toPx(),
                    margin = 16.dp.toPx(),
                    // The ring's outset and its 3dp stroke, plus a little air,
                    // so the tip stops just short of it.
                    ringGap = (RING_OUTSET + 4.dp).toPx(),
                    tailHalfWidth = TAIL_HALF_WIDTH.toPx(),
                    cornerRadius = CORNER_RADIUS.toPx(),
                    noAnchorBottom = 120.dp.toPx(),
                )
            }
        }
    }

    val cardWidth: Float = minOf(metrics.maxWidth, width - 2 * metrics.margin)
    val x: Float
    val tail: Tail?
    private val top: Float?
    private val bottom: Float

    init {
        if (anchor == null) {
            x = (width - cardWidth) / 2
            tail = null
            top = null
            bottom = height - metrics.noAnchorBottom
        } else {
            val center = anchor.center.x.coerceIn(cardWidth / 2 + metrics.margin, width - cardWidth / 2 - metrics.margin)
            x = center - cardWidth / 2
            val inset = metrics.cornerRadius + metrics.tailHalfWidth
            val tipX = (anchor.center.x - x).coerceIn(inset, cardWidth - inset)
            if (anchor.center.y < height / 2) {
                top = anchor.bottom + metrics.ringGap
                bottom = 0f
                tail = Tail(TailEdge.TOP, tipX)
            } else {
                top = null
                bottom = anchor.top - metrics.ringGap
                tail = Tail(TailEdge.BOTTOM, tipX)
            }
        }
    }

    private val stageHeight = height

    /** The card's top, given its measured height (its tail included). Kept
     *  inside the stage: a short sheet would otherwise clip its buttons. */
    fun y(cardHeight: Float): Float =
        (top ?: (bottom - cardHeight)).coerceAtMost(stageHeight - cardHeight).coerceAtLeast(0f)

    companion object {
        val TAIL_HEIGHT = 10.dp
        val TAIL_HALF_WIDTH = 11.dp
        val CORNER_RADIUS = 18.dp
    }
}

/** The card's rounded body with a speech-bubble tail, as one outline so the
 *  border runs round the tail too. The tail takes [TutorialCardPlacement.TAIL_HEIGHT]
 *  of the card's own height. */
class TutorialCardShape(private val tail: TutorialCardPlacement.Tail?) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val h = with(density) { TutorialCardPlacement.TAIL_HEIGHT.toPx() }
        val w = with(density) { TutorialCardPlacement.TAIL_HALF_WIDTH.toPx() }
        val top = if (tail?.edge == TutorialCardPlacement.TailEdge.TOP) h else 0f
        val bottom = size.height - if (tail?.edge == TutorialCardPlacement.TailEdge.BOTTOM) h else 0f
        val r = minOf(with(density) { TutorialCardPlacement.CORNER_RADIUS.toPx() }, (bottom - top) / 2)
        val body = Path().apply {
            addRoundRect(RoundRect(Rect(0f, top, size.width, bottom), CornerRadius(r)))
        }
        if (tail == null) return Outline.Generic(body)
        val pointer = Path().apply {
            if (tail.edge == TutorialCardPlacement.TailEdge.TOP) {
                moveTo(tail.x - w, top)
                lineTo(tail.x, 0f)
                lineTo(tail.x + w, top)
            } else {
                moveTo(tail.x - w, bottom)
                lineTo(tail.x, size.height)
                lineTo(tail.x + w, bottom)
            }
            close()
        }
        return Outline.Generic(Path().apply { op(body, pointer, PathOperation.Union) })
    }
}
