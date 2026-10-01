package com.nostrvault.ui.components

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import java.util.UUID
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/**
 * A zap's trip across the whole window, ported from iOS `ZapFlightView`: the
 * sats leave *your* avatar in the bottom bar, arc over the content, land on
 * the bolt button of the note being zapped, and the screen glows for a beat.
 *
 * A row is clipped to its own card, so anything that crosses the screen has
 * to be drawn by something that owns the whole window: one [ZapFlightStage]
 * sits at the root of NavGraph, and rows only report where their bolt is.
 */
object ZapFlight {

    internal class Flight(
        val id: UUID = UUID.randomUUID(),
        val launchedAtNanos: Long,
        val durationSec: Double,
        val origin: Rect,
        val noteId: String,
        /** Sideways swing direction, fixed at launch so the arc never flips. */
        val bowSign: Float,
        val embers: List<Ember>,
    ) {
        var landed = false
    }

    /** A spark shed from the head partway along the path. */
    internal class Ember(val at: Double, val driftX: Float, val driftY: Float, val sizeDp: Float)

    internal val flights = mutableStateListOf<Flight>()

    // Root-space frames. Plain maps, not state: they move on every scroll
    // frame and nothing should recompose for that; a flight reads them per
    // frame, so a target scrolling mid-flight still gets hit.
    private val origins = HashMap<Any, Rect>()
    private var latestOrigin: Any? = null
    internal val targets = HashMap<String, Rect>()
    internal var stageBounds: Rect = Rect.Zero
    /** Pixels per dp, recorded by the stage so callers needn't pass it. */
    internal var density: Float = 1f

    private val main = Handler(Looper.getMainLooper())

    internal fun setOrigin(key: Any, rect: Rect) {
        origins[key] = rect
        latestOrigin = key
    }

    internal fun clearOrigin(key: Any) {
        origins.remove(key)
        if (latestOrigin == key) latestOrigin = origins.keys.firstOrNull()
    }

    private fun originFrame(): Rect {
        latestOrigin?.let { origins[it] }?.takeIf { it.width > 0f }?.let { return it }
        if (stageBounds.isEmpty) return Rect.Zero
        // Where the bottom bar's avatar sits, give or take.
        val half = 12f * density
        val cy = stageBounds.bottom - 64f * density
        return Rect(stageBounds.center.x - half, cy - half, stageBounds.center.x + half, cy + half)
    }

    /**
     * Flies the sats to the bolt on [noteId]. Call it only once the wallet has
     * paid: a failed zap must not play a success animation. Returns false,
     * drawing nothing, under Reduce Motion or when the bolt isn't on screen.
     */
    fun launch(noteId: String): Boolean {
        val origin = originFrame()
        val target = targets[noteId]
        if (Motion.isReduced || origin.isEmpty || target == null || target.isEmpty) return false

        val distance = (target.center - origin.center).getDistance() / density
        // Long enough to follow with your eye; long trips get a little more
        // so the speed reads the same.
        val duration = 0.85 + min(distance / 2000.0, 0.25)
        val flight = Flight(
            launchedAtNanos = System.nanoTime(),
            durationSec = duration,
            origin = origin,
            noteId = noteId,
            bowSign = if (target.center.x >= origin.center.x) -1f else 1f,
            embers = List(5) { i ->
                val angle = Random.nextDouble(0.0, 2 * Math.PI)
                val speed = Random.nextDouble(16.0, 38.0)
                Ember(
                    at = 0.14 + i * 0.12 + Random.nextDouble(-0.03, 0.03),
                    driftX = (cos(angle) * speed).toFloat(),
                    driftY = (sin(angle) * speed).toFloat(),
                    sizeDp = Random.nextDouble(1.8, 3.0).toFloat(),
                )
            },
        )
        flights.add(flight)
        main.postDelayed(
            { flights.removeAll { it.id == flight.id } },
            ((duration * ARRIVAL + LANDING_LIFE) * 1000).toLong(),
        )
        return true
    }

    /** Progress at which the head reaches the button and the landing starts. */
    internal const val ARRIVAL = 0.88
    /** How far back in time the trail reaches, as a fraction of the flight. */
    internal const val TRAIL_LENGTH = 0.14
    /** Seconds the landing (burst + screen glow) lasts. */
    internal const val LANDING_LIFE = 0.6
}

/**
 * Marks the signed-in account's avatar as where a zap takes off. When two
 * copies are on screen (the bottom bar mid-morph) the last to lay out wins,
 * and one leaving only clears its own frame.
 */
@Composable
fun Modifier.zapFlightOrigin(): Modifier {
    val key = remember { Any() }
    DisposableEffect(key) { onDispose { ZapFlight.clearOrigin(key) } }
    return this.onGloballyPositioned { ZapFlight.setOrigin(key, it.boundsInRoot()) }
}

/** Keeps the zap button's root-space frame current so a flight can land on it. */
@Composable
fun Modifier.zapFlightTarget(noteId: String): Modifier {
    DisposableEffect(noteId) { onDispose { ZapFlight.targets.remove(noteId) } }
    return this.onGloballyPositioned { ZapFlight.targets[noteId] = it.boundsInRoot() }
}

private val Amber = Color(1f, 0.62f, 0.1f)
private val HotWhite = Color(1f, 0.97f, 0.88f)

/** Draws every flight in progress. Mount once, above everything; never takes a touch. */
@Composable
fun ZapFlightStage(modifier: Modifier = Modifier) {
    val view = LocalView.current
    val bolt = rememberVectorPainter(NostrVaultIcons.Zap)
    var frameNanos by remember { mutableLongStateOf(0L) }
    val active = ZapFlight.flights.isNotEmpty()

    LaunchedEffect(active) {
        while (active) {
            withFrameNanos { now ->
                frameNanos = now
                for (f in ZapFlight.flights) {
                    if (!f.landed && (now - f.launchedAtNanos) / 1e9 >= f.durationSec * ZapFlight.ARRIVAL) {
                        f.landed = true
                        view.performHapticFeedback(
                            if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM
                            else HapticFeedbackConstants.VIRTUAL_KEY,
                        )
                    }
                }
            }
        }
    }

    Canvas(
        modifier
            .fillMaxSize()
            .clearAndSetSemantics {}
            .onGloballyPositioned { ZapFlight.stageBounds = it.boundsInRoot() },
    ) {
        ZapFlight.density = density
        if (!active) return@Canvas
        val stage = ZapFlight.stageBounds
        translate(-stage.left, -stage.top) {
            for (flight in ZapFlight.flights) {
                drawFlight(flight, frameNanos, stage) { alpha ->
                    with(bolt) { draw(Size(34.dp.toPx(), 34.dp.toPx()), alpha, ColorFilter.tint(HotWhite)) }
                }
            }
        }
    }
}

private fun cubicBezierY(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
    fun coord(s: Double, p1: Double, p2: Double): Double {
        val ms = 1 - s
        return 3 * ms * ms * s * p1 + 3 * ms * s * s * p2 + s * s * s
    }
    var lo = 0.0
    var hi = 1.0
    var s = x
    repeat(20) {
        s = (lo + hi) / 2
        if (coord(s, x1, x2) < x) lo = s else hi = s
    }
    return coord(s, y1, y2)
}

/** Picks up speed off the avatar and settles into the button without bouncing past it. */
private fun eased(u: Double): Float = cubicBezierY(u.coerceIn(0.0, 1.0), 0.4, 0.05, 0.2, 1.0).toFloat()

/** Lifts off steeply, swings out to one side and curls back in: a throw, not a rail. */
private fun DrawScope.pathPoint(t: Float, start: Offset, end: Offset, bowSign: Float): Offset {
    val dx = end.x - start.x
    val dy = end.y - start.y
    val length = max(hypot(dx, dy), 1f)
    val nx = -dy / length
    val ny = dx / length
    val swing = (length * 0.45f).coerceIn(150.dp.toPx(), 240.dp.toPx()) * bowSign
    val p1 = Offset(start.x + dx * 0.2f + nx * swing, start.y + dy * 0.2f + ny * swing)
    val p2 = Offset(start.x + dx * 0.8f + nx * swing * 0.35f, start.y + dy * 0.8f + ny * swing * 0.35f)
    val mt = 1 - t
    val a = mt * mt * mt
    val b = 3 * mt * mt * t
    val c = 3 * mt * t * t
    val d = t * t * t
    return Offset(a * start.x + b * p1.x + c * p2.x + d * end.x, a * start.y + b * p1.y + c * p2.y + d * end.y)
}

private fun DrawScope.drawFlight(flight: ZapFlight.Flight, nowNanos: Long, stage: Rect, drawBolt: DrawScope.(alpha: Float) -> Unit) {
    val elapsed = max(0.0, (nowNanos - flight.launchedAtNanos) / 1e9)
    val u = min(elapsed / flight.durationSec, 1.0)
    val start = flight.origin.center
    val end = ZapFlight.targets[flight.noteId]?.takeIf { !it.isEmpty }?.center ?: start
    val t = eased(u)
    val point = { p: Float -> pathPoint(p, start, end, flight.bowSign) }

    // Launch: a ring leaves your avatar's edge, like a charge letting go.
    if (u < 0.35) {
        val k = (u / 0.35).toFloat()
        drawCircle(
            Amber.copy(alpha = 0.85f * (1 - k)),
            radius = flight.origin.width / 2 + 2.dp.toPx() + k * 26.dp.toPx(),
            center = start,
            style = Stroke((2.5f * (1 - k) + 0.5f).dp.toPx()),
            blendMode = BlendMode.Plus,
        )
    }

    // Head fades in fast off the avatar and sinks into the button at the end.
    val arrival = ZapFlight.ARRIVAL
    val headAlpha = when {
        u < 0.08 -> u / 0.08
        u > arrival -> max(0.0, 1 - (u - arrival) / (1 - arrival))
        else -> 1.0
    }.toFloat()

    // Trail: overlapping strokes that all run to the head, shorter ones
    // wider, so under additive blending it thickens and brightens toward
    // the head with no seams.
    if (headAlpha > 0f) {
        val tail = eased(u - ZapFlight.TRAIL_LENGTH)
        val layers = 6
        for (layer in 0 until layers) {
            val f = layer.toFloat() / layers
            val from = tail + (t - tail) * f
            var prev = point(from)
            val color = (if (layer == layers - 1) Color.White else Amber).copy(alpha = 0.36f * headAlpha)
            val width = (2f + 7f * f).dp.toPx()
            for (i in 1..12) {
                val next = point(from + (t - from) * i / 12f)
                drawLine(color, prev, next, strokeWidth = width, cap = StrokeCap.Round, blendMode = BlendMode.Plus)
                prev = next
            }
        }
    }

    // Embers shed along the way, drifting, falling and dimming.
    for (ember in flight.embers) {
        if (u <= ember.at) continue
        val age = ((u - ember.at) * flight.durationSec).toFloat()
        val life = 0.34f
        if (age >= life) continue
        val o = point(eased(ember.at))
        val at = Offset(
            o.x + (ember.driftX * age).dp.toPx(),
            o.y + (ember.driftY * age + 40f * age * age).dp.toPx(),
        )
        drawCircle(Amber.copy(alpha = 0.9f * (1 - age / life)), ember.sizeDp.dp.toPx() / 2, at, blendMode = BlendMode.Plus)
    }

    // Landing: a burst on the button, warm light flooding out from it, and
    // the screen's edges glowing for a beat.
    val landed = ((elapsed - flight.durationSec * arrival) / ZapFlight.LANDING_LIFE).toFloat()
    if (landed > 0f && landed < 1f) {
        val strength = if (landed < 0.15f) landed / 0.15f else 1 - (landed - 0.15f) / 0.85f
        drawRect(
            Brush.radialGradient(
                0f to Amber.copy(alpha = 0.42f * strength),
                0.45f to Amber.copy(alpha = 0.12f * strength),
                1f to Color.Transparent,
                center = end,
                radius = (140f + 520f * landed).dp.toPx(),
            ),
            topLeft = stage.topLeft,
            size = stage.size,
            blendMode = BlendMode.Plus,
        )
        val edge = 36.dp.toPx()
        val glow = Amber.copy(alpha = 0.55f * strength)
        drawRect(Brush.verticalGradient(listOf(glow, Color.Transparent), stage.top, stage.top + edge), stage.topLeft, Size(stage.width, edge))
        drawRect(Brush.verticalGradient(listOf(Color.Transparent, glow), stage.bottom - edge, stage.bottom), Offset(stage.left, stage.bottom - edge), Size(stage.width, edge))
        drawRect(Brush.horizontalGradient(listOf(glow, Color.Transparent), stage.left, stage.left + edge), stage.topLeft, Size(edge, stage.height))
        drawRect(Brush.horizontalGradient(listOf(Color.Transparent, glow), stage.right - edge, stage.right), Offset(stage.right - edge, stage.top), Size(edge, stage.height))

        // Burst on the bolt: expanding ring and a small scatter of sparks.
        drawCircle(Amber.copy(alpha = 0.75f * (1 - landed)), (11f + 16f * landed).dp.toPx(), end, style = Stroke(1.5.dp.toPx()))
        for (i in 0 until 6) {
            val angle = i / 6.0 * 2 * Math.PI + flight.bowSign * 0.2
            val dist = 22.dp.toPx() * landed
            drawCircle(
                Amber.copy(alpha = 1 - landed),
                1.6.dp.toPx(),
                Offset(end.x + (cos(angle) * dist).toFloat(), end.y + (sin(angle) * dist).toFloat()),
            )
        }
    }

    // Head: a white-hot bolt with an amber halo, leaning into its travel.
    if (headAlpha <= 0f) return
    val here = point(t)
    val ahead = point(min(t + 0.02f, 1f))
    val behind = point(max(t - 0.02f, 0f))
    val lean = (atan2(ahead.x - behind.x, -(ahead.y - behind.y)) * 0.4f).coerceIn(-0.35f, 0.35f)
    val scale = if (u > arrival) 1 - 0.4f * ((u - arrival) / (1 - arrival)).toFloat() else 1f
    drawCircle(
        Brush.radialGradient(listOf(Amber.copy(alpha = 0.7f * headAlpha), Color.Transparent), here, 30.dp.toPx() * scale),
        30.dp.toPx() * scale,
        here,
        blendMode = BlendMode.Plus,
    )
    val half = 17.dp.toPx()
    translate(here.x - half, here.y - half) {
        rotate(Math.toDegrees(lean.toDouble()).toFloat(), pivot = Offset(half, half)) {
            scale(scale, pivot = Offset(half, half)) {
                drawBolt(headAlpha)
            }
        }
    }
}
