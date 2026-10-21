package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeBolt
import com.nostrvault.data.model.GlobeEdge
import com.nostrvault.data.model.GlobeZaps
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Draws zaps as lightning bolts (iOS `GlobeBoltPainter`): a jagged white core in
 * a warm electric glow, with a short fork, striking from the zapper to the person
 * zapped in an instant, flickering while it flashes, then an afterglow. A bolt
 * round the back dims like the stars ([GlobeEdge]). Reduce Motion: one plain,
 * steady line that fades. No blur on every Android version: wide, faint strokes
 * stand in for iOS's blurred glow layers, as the globe's threads do.
 */
internal object GlobeBoltPainter {
    /** Zap gold, so a bolt never reads as a note's white star. */
    val BoltColor = Color(red = 1f, green = 0.84f, blue = 0.32f)

    class Shape(
        val main: Path,
        val fork: Path,
        val end: Offset?,
        val alpha: Double,
        val landing: Double,
        /** How hard it strikes, 0 to 1, by the zap's amount. */
        val strength: Double,
        /** True while it flashes (white-hot), false in its afterglow. */
        val flash: Boolean,
    )

    /**
     * One bolt's shape this frame. [at] is a point on its arc, 0 at the zapper and
     * 1 at the person zapped, already on screen.
     */
    fun shape(
        line: GlobeArcs.Line,
        stage: GlobeArcs.Stage,
        now: Double,
        reduceMotion: Boolean,
        at: (Double) -> GlobeScene.Projected?,
    ): Shape? {
        val n = GlobeBolt.SEGMENTS
        // Points the camera can't see (zoomed in past them) break the bolt, the
        // way a star's trail breaks, rather than hiding all of it.
        val points = (0..n).map { at(stage.head * it / n) }
        val seen = points.filterNotNull()
        if (seen.size < 2) return null
        // Jagged across the screen, in proportion to the whole bolt's length.
        val whole = at(1.0) ?: seen.last()
        val origin = at(0.0) ?: seen.first()
        val length = hypot(whole.x - origin.x, whole.y - origin.y)
        val seed = GlobeBolt.seed(line.note)
        val flickers = GlobeZaps.boltFlickers(line, now)
        val frame = GlobeBolt.frame(now - line.born, flickers)
        val offsets = GlobeBolt.offsets(seed, frame, reduceMotion)
        val jagged = (0..n).map { i ->
            val p = points[i] ?: return@map null
            val before = points[max(0, i - 1)] ?: p
            val after = points[min(n, i + 1)] ?: p
            val dx = after.x - before.x
            val dy = after.y - before.y
            val d = max(0.001, hypot(dx, dy))
            Offset((p.x - dy / d * offsets[i] * length).toFloat(), (p.y + dx / d * offsets[i] * length).toFloat())
        }
        val depth = (at(0.5) ?: seen[seen.size / 2]).depth
        // While it flashes it flickers (not under Reduce Motion) and burns white-hot.
        val flashing = flickers && !reduceMotion
        val flicker = if (flashing) GlobeBolt.flicker(seed, frame) else 1.0
        val alpha = stage.alpha * GlobeEdge.arc(depth) * flicker
        if (alpha <= 0.01) return null
        val main = Path()
        var open = false
        for (p in jagged) {
            if (p == null) { open = false; continue }
            if (open) main.lineTo(p.x, p.y) else { main.moveTo(p.x, p.y); open = true }
        }
        val forkPath = Path()
        // A short fork off the middle third, two for a strong zap, once the bolt has passed it.
        if (!reduceMotion) for (fork in GlobeBolt.forks(seed, line.strength)) {
            if (fork.from >= n || fork.from.toDouble() / n >= stage.head) continue
            val a = jagged[fork.from] ?: continue
            val b = jagged[fork.from + 1] ?: continue
            val angle = atan2((b.y - a.y).toDouble(), (b.x - a.x).toDouble()) + fork.turn
            val reach = fork.length * length
            val kink = offsets[fork.from] * length * 0.8
            forkPath.moveTo(a.x, a.y)
            forkPath.lineTo((a.x + cos(angle) * reach * 0.5 - sin(angle) * kink).toFloat(),
                (a.y + sin(angle) * reach * 0.5 + cos(angle) * kink).toFloat())
            forkPath.lineTo((a.x + cos(angle) * reach).toFloat(), (a.y + sin(angle) * reach).toFloat())
        }
        return Shape(main, forkPath, if (stage.head >= 1) jagged[n] else null, alpha, stage.landing, line.strength, flashing)
    }

    /** [unit] is pixels per iOS point at this screen size. */
    fun draw(scope: DrawScope, shapes: List<Shape>, unit: Float) = with(scope) {
        if (shapes.isEmpty()) return@with
        fun stroke(width: Double) = Stroke(width = width.toFloat() * unit, cap = StrokeCap.Round, join = StrokeJoin.Round)
        // The glow; a stronger zap glows wider.
        for (s in shapes) {
            val a = s.alpha.toFloat()
            drawPath(s.main, BoltColor.copy(alpha = 0.22f * a), style = stroke(10 + 10 * s.strength))
            drawPath(s.main, BoltColor.copy(alpha = 0.45f * a), style = stroke(5 + 5 * s.strength))
            drawPath(s.fork, BoltColor.copy(alpha = 0.4f * a), style = stroke(3 + 2 * s.strength))
            // While it flashes, a white-hot bloom along the core.
            if (s.flash) drawPath(s.main, Color.White.copy(alpha = 0.5f * a), style = stroke(3 + 3 * s.strength))
        }
        for (s in shapes) {
            val a = s.alpha.toFloat()
            drawPath(s.main, Color.White.copy(alpha = a), style = stroke(1.6 + 1.2 * s.strength))
            drawPath(s.fork, Color.White.copy(alpha = 0.8f * a), style = stroke(0.9 + 0.5 * s.strength))
            // Where it strikes: a gold burst that opens and fades, and a thin ring
            // running out from it. Bigger for a bigger zap.
            val p = s.end ?: continue
            val scale = (1 + 0.8 * s.strength) * unit
            val r = ((6 + 16 * s.landing) * scale).toFloat()
            if (r > 0f) {
                drawCircle(
                    brush = Brush.radialGradient(
                        0f to Color.White.copy(alpha = (0.9 * s.alpha * (1 - s.landing)).toFloat()),
                        0.5f to BoltColor.copy(alpha = (0.8 * s.alpha * (1 - 0.6 * s.landing)).toFloat()),
                        1f to Color.Transparent,
                        center = p, radius = r,
                    ),
                    radius = r, center = p,
                )
            }
            val ring = ((8 + 26 * s.landing) * scale).toFloat()
            drawCircle(BoltColor.copy(alpha = (0.6 * s.alpha * (1 - s.landing)).toFloat()), radius = ring, center = p,
                style = Stroke(width = 1.2f * unit))
        }
    }
}
