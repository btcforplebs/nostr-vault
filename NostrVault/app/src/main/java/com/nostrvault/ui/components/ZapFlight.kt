package com.nostrvault.ui.components

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
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
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.Motion
import java.util.UUID
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/**
 * A zap's strike across the whole window, ported from iOS `ZapFlightView`
 * (#119): a lightning bolt cracks from *your* avatar in the bottom bar to the
 * bolt button of the note being zapped. Direction matters: the sats are yours
 * going out, so the strike starts at you, not at the author.
 *
 * It plays like real lightning: a dim, jagged leader feels its way across in
 * steps, then the return stroke slams the whole channel white with a brief
 * screen flash, strobes a few times and dies into an amber afterglow, with a
 * haptic crack on the strike ([ZapHaptics]). Shape and timing live in
 * [ZapBolt].
 *
 * A row is clipped to its own card, so anything that crosses the screen has
 * to be drawn by something that owns the whole window: one [ZapFlightStage]
 * sits at the root of NavGraph, and rows only report where their bolt is.
 */
object ZapFlight {

    internal class Flight(
        val id: UUID = UUID.randomUUID(),
        val launchedAtNanos: Long,
        val origin: Rect,
        val noteId: String,
        /**
         * Several jagged shapes of the same channel; each strobe of the
         * return stroke shows the next, so the bolt crackles instead of
         * sitting still.
         */
        val channels: List<List<ZapBolt.Point>>,
        val branches: List<ZapBolt.Branch>,
    ) {
        var charged = false
        var struck = false
    }

    internal val flights = mutableStateListOf<Flight>()

    // Root-space frames. Plain maps, not state: they move on every scroll
    // frame and nothing should recompose for that; a strike reads them per
    // frame, so a target scrolling mid-strike still gets hit.
    private val origins = HashMap<Any, Rect>()
    private var latestOrigin: Any? = null
    internal val targets = HashMap<String, Rect>()
    internal var stageBounds: Rect = Rect.Zero
    /** Pixels per dp, recorded by the stage so callers needn't pass it. */
    internal var density: Float = 1f

    /** When the custom-amount sheet last confirmed a zap; see [sheetConfirmed]. */
    private var sheetConfirmedAtMs: Long = Long.MIN_VALUE

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
     * The custom-amount sheet calls this as its Zap button confirms, so a
     * strike that follows quickly waits for the sheet to clear rather than
     * crossing a screen the sheet still covers (iOS #126).
     */
    fun sheetConfirmed() {
        sheetConfirmedAtMs = SystemClock.uptimeMillis()
    }

    /**
     * Strikes the bolt on [noteId]. Call it only once the wallet has paid: a
     * failed zap must not play a success animation. Returns false, drawing
     * nothing, under Reduce Motion (animator duration scale off) or when the
     * bolt isn't on screen.
     */
    fun launch(noteId: String): Boolean {
        if (!canLaunch(noteId)) return false
        val wait = ZapBolt.sheetWaitMs(SystemClock.uptimeMillis(), sheetConfirmedAtMs)
        if (wait > 0) {
            main.postDelayed({ if (canLaunch(noteId)) start(noteId) }, wait)
        } else {
            start(noteId)
        }
        return true
    }

    private fun canLaunch(noteId: String): Boolean {
        val target = targets[noteId]
        return !Motion.isReduced && !originFrame().isEmpty && target != null && !target.isEmpty
    }

    private fun start(noteId: String) {
        val origin = originFrame()
        val target = targets[noteId] ?: return
        val lengthDp = (target.center - origin.center).getDistance() / density
        val flight = Flight(
            launchedAtNanos = System.nanoTime(),
            origin = origin,
            noteId = noteId,
            channels = List(ZapBolt.STROBES.size) { ZapBolt.channel(lengthDp) },
            branches = ZapBolt.branches(lengthDp),
        )
        flights.add(flight)
        main.postDelayed({ flights.removeAll { it.id == flight.id } }, (ZapBolt.TOTAL * 1000).toLong())
    }
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
private val Hot = Color(1f, 0.93f, 0.7f)
private val Violet = Color(0.72f, 0.6f, 1f)

/**
 * Draws every strike in progress. Mount once, above everything; never takes
 * a touch. The drawing layer only exists while a strike plays — at rest this
 * is an empty box that measures the window.
 */
@Composable
fun ZapFlightStage(modifier: Modifier = Modifier) {
    val view = LocalView.current
    val density = LocalDensity.current.density
    SideEffect { ZapFlight.density = density }
    val active = ZapFlight.flights.isNotEmpty()

    Box(
        modifier
            .fillMaxSize()
            .clearAndSetSemantics {}
            .onGloballyPositioned { ZapFlight.stageBounds = it.boundsInRoot() },
    ) {
        if (active) {
            var frameNanos by remember { mutableLongStateOf(System.nanoTime()) }
            LaunchedEffect(Unit) {
                while (true) {
                    withFrameNanos { now ->
                        frameNanos = now
                        for (f in ZapFlight.flights) {
                            val elapsed = (now - f.launchedAtNanos) / 1e9
                            if (!f.charged) {
                                f.charged = true
                                ZapHaptics.charge(view)
                            }
                            if (!f.struck && elapsed >= ZapBolt.STRIKE_AT) {
                                f.struck = true
                                ZapHaptics.strike(view)
                            }
                        }
                    }
                }
            }
            Canvas(Modifier.fillMaxSize()) {
                val stage = ZapFlight.stageBounds
                translate(-stage.left, -stage.top) {
                    for (flight in ZapFlight.flights) drawStrike(flight, frameNanos, stage)
                }
            }
        }
    }
}

private fun DrawScope.drawStrike(flight: ZapFlight.Flight, nowNanos: Long, stage: Rect) {
    val elapsed = (nowNanos - flight.launchedAtNanos) / 1e9
    val frame = ZapBolt.frame(elapsed)
    val start = flight.origin.center
    val end = ZapFlight.targets[flight.noteId]?.takeIf { !it.isEmpty }?.center ?: start
    val place = { p: ZapBolt.Point -> ZapBolt.place(p, start, end, density) }

    // Charge: the avatar crackles while the leader sets off.
    frame.charge?.let { k ->
        val flicker = Random.nextDouble(0.5, 1.0).toFloat()
        val radius = flight.origin.width / 2 + (3f + k.toFloat() * 8f).dp.toPx()
        // iOS puts a 10 pt amber shadow under the ring; two soft amber rings stand in.
        drawCircle(Amber.copy(alpha = 0.18f * flicker), radius, start, style = Stroke(14.dp.toPx()), blendMode = BlendMode.Plus)
        drawCircle(Amber.copy(alpha = 0.35f * flicker), radius, start, style = Stroke(7.dp.toPx()), blendMode = BlendMode.Plus)
        drawCircle(Hot.copy(alpha = 0.8f * flicker), radius, start, style = Stroke(2.dp.toPx()), blendMode = BlendMode.Plus)
    }

    frame.leaderReach?.let { reach ->
        // Stepped leader: dim, thin, advancing in jumps rather than a smooth
        // slide, each step re-jittering what is already there.
        val channel = flight.channels[frame.leaderChannel % flight.channels.size]
        val shown = channel.filter { it.along <= reach }
        if (shown.size < 2) return
        strokeBolt(shown.map(place), 1.6f, 0.55f * Random.nextDouble(0.6, 1.0).toFloat())
        for (branch in flight.branches) {
            if (branch.reach > reach) continue
            val base = place(channel[min(branch.fromIndex, channel.size - 1)])
            strokeBolt(ZapBolt.placeBranch(branch, base, start, end, density), 1f, 0.35f)
        }
        return
    }

    // Return stroke: the whole channel slams white, then strobes.
    frame.strobe?.let { index ->
        val brightness = frame.strobeBrightness.toFloat()
        val channel = flight.channels[index % flight.channels.size].map(place)
        // The flash: the screen goes white for an instant.
        if (frame.flash) drawRect(Color.White.copy(alpha = 0.22f), stage.topLeft, stage.size)
        strokeBolt(channel, 6f, brightness)
        for (branch in flight.branches) {
            val base = channel[min(branch.fromIndex, channel.size - 1)]
            strokeBolt(ZapBolt.placeBranch(branch, base, start, end, density), 2f, brightness * 0.7f)
        }
    }

    // Afterglow: warm light floods out from the button and the screen's edges
    // glow for a beat, then it all falls away.
    frame.glow?.let { g ->
        val strength = ZapBolt.glowStrength(g).toFloat()
        val landed = g.toFloat()
        drawRect(
            Brush.radialGradient(
                0f to Amber.copy(alpha = 0.5f * strength),
                0.5f to Amber.copy(alpha = 0.14f * strength),
                1f to Color.Transparent,
                center = end,
                radius = (120f + 520f * landed).dp.toPx(),
            ),
            topLeft = stage.topLeft,
            size = stage.size,
            blendMode = BlendMode.Plus,
        )
        val edge = 36.dp.toPx()
        val glow = Amber.copy(alpha = 0.6f * strength)
        drawRect(Brush.verticalGradient(listOf(glow, Color.Transparent), stage.top, stage.top + edge), stage.topLeft, Size(stage.width, edge), blendMode = BlendMode.Plus)
        drawRect(Brush.verticalGradient(listOf(Color.Transparent, glow), stage.bottom - edge, stage.bottom), Offset(stage.left, stage.bottom - edge), Size(stage.width, edge), blendMode = BlendMode.Plus)
        drawRect(Brush.horizontalGradient(listOf(glow, Color.Transparent), stage.left, stage.left + edge), stage.topLeft, Size(edge, stage.height), blendMode = BlendMode.Plus)
        drawRect(Brush.horizontalGradient(listOf(Color.Transparent, glow), stage.right - edge, stage.right), Offset(stage.right - edge, stage.top), Size(edge, stage.height), blendMode = BlendMode.Plus)

        // Burst on the bolt — the stand-in for iOS's ZapBurstView, which the
        // strike sets off there: an expanding ring and a scatter of sparks.
        drawCircle(Amber.copy(alpha = 0.75f * (1 - landed)), (11f + 16f * landed).dp.toPx(), end, style = Stroke(1.5.dp.toPx()))
        for (i in 0 until 6) {
            val angle = i / 6.0 * 2 * Math.PI
            val dist = 22.dp.toPx() * landed
            drawCircle(
                Amber.copy(alpha = 1 - landed),
                1.6.dp.toPx(),
                Offset(end.x + (cos(angle) * dist).toFloat(), end.y + (sin(angle) * dist).toFloat()),
            )
        }
    }
}

/**
 * A bolt as three passes under additive blending: a wide violet-amber halo,
 * a hot yellow body and a thin white core. iOS blurs the halo; Compose's
 * DrawScope has no per-stroke blur on every API level this app supports, so
 * the halo is stacked strokes, widest faintest, which add up to the same
 * soft falloff.
 */
private fun DrawScope.strokeBolt(points: List<Offset>, widthDp: Float, brightness: Float) {
    if (points.size < 2 || brightness <= 0.01f) return
    val path = Path().apply {
        moveTo(points[0].x, points[0].y)
        for (i in 1 until points.size) lineTo(points[i].x, points[i].y)
    }
    val width = widthDp.dp.toPx()
    fun pass(color: Color, alpha: Float, w: Float) = drawPath(
        path,
        color.copy(alpha = alpha.coerceIn(0f, 1f)),
        style = Stroke(w, cap = StrokeCap.Round, join = StrokeJoin.Miter),
        blendMode = BlendMode.Plus,
    )
    for (k in HALO_VIOLET) pass(Violet, 0.5f * brightness * HALO_SHARE, width * k)
    for (k in HALO_AMBER) pass(Amber, 0.7f * brightness * HALO_SHARE, width * k)
    pass(Hot, 0.9f * brightness, width * 1.6f)
    pass(Color.White, brightness, max(width * 0.6f, 1.dp.toPx()))
}

private val HALO_VIOLET = floatArrayOf(9f, 7f, 5f, 3.5f)
private val HALO_AMBER = floatArrayOf(4.5f, 3f, 2f)
/** Each stacked halo pass's share of the iOS halo's opacity. */
private const val HALO_SHARE = 0.3f
