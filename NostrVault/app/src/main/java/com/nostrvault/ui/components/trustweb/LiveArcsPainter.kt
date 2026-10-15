package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeEdge
import com.nostrvault.data.model.GlobeStorm
import com.nostrvault.data.model.Vec3
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

/**
 * Draws the live arcs for one frame (iOS `LiveArcsPainter`): shooting stars,
 * their faint trails, and the lights where they land, over the stars and
 * threads and under the faces. Paths are gathered by how they're drawn: all at
 * one opacity step and size are one fill or stroke, so a storm of hundreds of
 * lines costs a few dozen draws, not thousands. Paths are kept between frames
 * and emptied, so a warm frame allocates little.
 */
internal class LiveArcsPainter {
    private class Batch {
        val paths = HashMap<Int, Path>()
        val used = HashSet<Int>()
        fun path(key: Int): Path {
            val path = paths.getOrPut(key) { Path() }
            if (used.add(key)) path.reset()
            return path
        }
        fun begin() = used.clear()
    }

    private val trails = Batch()
    private val tails = Batch()
    private val cores = Batch()
    private val glows = Batch()
    private val rings = Batch()

    fun drawLines(
        scope: DrawScope,
        board: GlobeArcs.Board,
        now: Double,
        reduceMotion: Boolean,
        /** Pixels for one of iOS's points at this screen size (its `k`, floored at 0.8, times density). */
        unit: Double,
        /** Pixels per dp, for line widths. */
        dp: Float,
        facing: Vec3,
        project: (Vec3) -> GlobeScene.Projected?,
        place: (String, GlobeArcs.Ring?) -> Vec3,
    ) = with(scope) {
        for (batch in arrayOf(trails, tails, cores, glows, rings)) batch.begin()
        // Lights breathe slowly while they stay.
        val breath = if (reduceMotion) 1.0 else 0.82 + 0.18 * sin(now * 2 * PI / 2.6)
        val samples = GlobeStorm.arcSamples(board.lines.size)
        for (line in board.lines) {
            val stage = GlobeArcs.stage(line, now, reduceMotion)
            if (stage.alpha <= 0.01) continue
            val a = place(line.from, line.ring)
            val b = place(line.to, null)
            fun at(t: Double) = project(GlobeArcs.point(a, b, t, facing))
            // The faint trail it leaves, gone soon after it lands.
            val trailBand = GlobeStorm.band(stage.trail)
            if (trailBand > 0) {
                val path = trails.path(trailBand)
                var open = false
                for (s in 0..samples) {
                    val p = at(stage.head * s / samples)
                    if (p == null) { open = false; continue }
                    if (open) path.lineTo(p.x.toFloat(), p.y.toFloat()) else { path.moveTo(p.x.toFloat(), p.y.toFloat()); open = true }
                }
            }
            // A reaction's star, tail and landing are smaller than a note's.
            val sizeIndex = if (line.sort == GlobeArcs.Sort.REACTION) 1 else 0
            val size = sizeOf(sizeIndex)
            // In flight: the star and its short tail, brightest at the star.
            val head = if (stage.head < 1) at(stage.head) else null
            if (head != null) {
                // Round the back a star dims smoothly, never switches.
                val behind = GlobeEdge.arc(head.depth)
                val start = max(0.0, stage.head - GlobeArcs.TAIL_LENGTH)
                var last = at(start)
                for (step in 1..TAIL_STEPS) {
                    val t = start + (stage.head - start) * step / TAIL_STEPS
                    val p = at(t)
                    if (p == null) { last = null; continue }
                    val f = step.toDouble() / TAIL_STEPS
                    val band = GlobeStorm.band(f * f * stage.alpha * behind)
                    val from = last
                    if (from != null && band > 0) {
                        tails.path((band * 16 + step) * 2 + sizeIndex).apply {
                            moveTo(from.x.toFloat(), from.y.toFloat())
                            lineTo(p.x.toFloat(), p.y.toFloat())
                        }
                    }
                    last = p
                }
                val band = GlobeStorm.band(stage.alpha * behind)
                if (band > 0) {
                    val r = 1.8 * size * unit
                    cores.path(band * 2 + sizeIndex).disc(head, r)
                    glows.path(band * 2 + sizeIndex).disc(head, 2 * r)
                }
            }
            // Where it lands: a small ring opens once, then a light stays and breathes.
            val landed = if (stage.landing > 0) project(b) else null
            if (landed != null) {
                val ringBand = GlobeStorm.band(0.5 * (1 - stage.landing) * stage.alpha)
                if (ringBand > 0) rings.path(ringBand).disc(landed, (5 + 14 * stage.landing) * size * unit)
                val band = GlobeStorm.band(0.7 * stage.alpha * breath)
                if (band > 0) {
                    val r = 1.8 * size * unit
                    cores.path(band * 2 + sizeIndex).disc(landed, r)
                    glows.path(band * 2 + sizeIndex).disc(landed, 2 * r)
                }
            }
        }
        for (band in trails.used) {
            drawPath(trails.paths.getValue(band), StarColor.copy(alpha = (0.14 * GlobeStorm.bandAlpha(band)).toFloat()),
                style = Stroke(width = 0.8f * dp, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        // No blur on every Android version: a wider, fainter stroke and disc stand
        // in for iOS's blurred glow layer, as the globe's own threads do.
        for (key in tails.used) {
            drawPath(tails.paths.getValue(key), StarColor.copy(alpha = (0.25 * GlobeStorm.bandAlpha(key / 32)).toFloat()),
                style = Stroke(width = (tailWidth(key) + 2) * dp * 1.6f, cap = StrokeCap.Round))
        }
        for (key in glows.used) {
            drawPath(glows.paths.getValue(key), StarColor.copy(alpha = (0.3 * GlobeStorm.bandAlpha(key / 2)).toFloat()))
        }
        for (key in tails.used) {
            drawPath(tails.paths.getValue(key), StarColor.copy(alpha = (0.9 * GlobeStorm.bandAlpha(key / 32)).toFloat()),
                style = Stroke(width = tailWidth(key) * dp, cap = StrokeCap.Round))
        }
        for (key in cores.used) {
            drawPath(cores.paths.getValue(key), StarColor.copy(alpha = GlobeStorm.bandAlpha(key / 2).toFloat()))
        }
        for (band in rings.used) {
            drawPath(rings.paths.getValue(band), StarColor.copy(alpha = GlobeStorm.bandAlpha(band).toFloat()),
                style = Stroke(width = dp))
        }
    }

    private fun Path.disc(p: GlobeScene.Projected, r: Double) {
        addOval(Rect(Offset(p.x.toFloat(), p.y.toFloat()), r.toFloat()))
    }

    companion object {
        /** Every arrival is a small white star, like the stars of the globe itself. */
        val StarColor = Color.White
        /** A reaction's star beside a note's. */
        const val REACTION_SIZE = 0.6
        /** Steps in a star's tail, each a little fainter and thinner than the last. */
        const val TAIL_STEPS = 8

        private fun sizeOf(index: Int) = if (index == 1) REACTION_SIZE else 1.0

        /** A tail segment's width in points, by its step and size, from its batch key. */
        private fun tailWidth(key: Int): Float {
            val step = (key / 2) % 16
            return ((0.4 + 1.4 * step / TAIL_STEPS) * sizeOf(key % 2)).toFloat()
        }
    }
}
