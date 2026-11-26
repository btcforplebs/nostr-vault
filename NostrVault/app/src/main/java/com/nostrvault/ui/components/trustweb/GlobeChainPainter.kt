package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.nostrvault.data.model.GlobeChain
import com.nostrvault.data.model.TrustMapOuter
import kotlin.math.max
import kotlin.math.min

/**
 * Draws a hop sphere person's path in to you ([GlobeChain], Logen
 * 2026-11-25): from their face through each link's spot on its layer (the
 * nested spheres, then the inner globe) to you at the centre. Points are
 * found again every frame, so the line follows the layers as they spin. A
 * link not on screen is skipped: the line runs straight on to the next. It
 * draws in from them toward you, like the inner globe's threads. Thin and
 * clean: a 1.4 dp line, a soft glow under it, a ring on the tapped person and
 * a bead on each layer it passes. iOS `Views/TrustWeb/GlobeChainPainter.swift`.
 */
internal object GlobeChainPainter {
    /** How long the line takes to draw in, seconds. */
    const val DRAW_IN = 0.6

    /** The path's accent: iOS's system orange. */
    val Accent: Color get() = if (globeDay) Color(0xFFFF9500) else Color(0xFFFF9F0A)

    /** A path to draw this frame: [points] from the tapped person to you, [ringsStart] when the first is theirs. */
    class Frame(val points: List<GlobeHopSphere.Point>, val ringsStart: Boolean, val progress: Double)

    /**
     * This frame's path for [links] (born at [born]): each link's spot on its
     * hop sphere, or for hop 2 and in on the inner globe ([scene]), then the
     * core. Null when there is nothing to draw.
     */
    fun frame(links: List<GlobeChain.Link>, born: Double, now: Double, scene: GlobeScene, w: Float, h: Float): Frame? {
        if (links.isEmpty()) return null
        val found = links.map { link ->
            val hop = link.hop
            if (hop != null && hop >= TrustMapOuter.FIRST_HOP) GlobeHopSphere.screenPoint(link.key, hop)
            else scene.screenPoint(link.key, w, h) ?: GlobeHopSphere.screenPoint(link.key, null)
        }
        val core = scene.screenPoint(null, w, h) ?: return null
        val (points, startsAtTapped) = GlobeChain.path(found)
        val progress = min(1.0, max(0.0, (now - born) / DRAW_IN))
        if (points.isEmpty() || progress <= 0) return null
        return Frame(points + core, startsAtTapped, progress)
    }

    /** The drawn-in part of the path, leg by leg, with each leg's mean nearness. */
    private inline fun legs(f: Frame, each: (Offset, Offset, Double) -> Unit) {
        val pts = f.points
        val legs = (pts.size - 1).toDouble()
        for (i in 0 until pts.size - 1) {
            val share = min(1.0, max(0.0, f.progress * legs - i))
            if (share <= 0) break
            val a = pts[i]
            val b = pts[i + 1]
            val end = Offset((a.x + (b.x - a.x) * share).toFloat(), (a.y + (b.y - a.y) * share).toFloat())
            each(Offset(a.x.toFloat(), a.y.toFloat()), end, (a.front + b.front) / 2)
        }
    }

    /** The glow under the line. [blurred]: drawn into a layer [GlobeThreads.glowBlur] blurs; else two soft strokes stand in. */
    fun drawGlow(scope: DrawScope, f: Frame, blurred: Boolean) = with(scope) {
        val path = Path()
        legs(f) { a, b, _ -> path.moveTo(a.x, a.y); path.lineTo(b.x, b.y) }
        if (blurred) {
            drawPath(path, Accent.copy(alpha = 0.55f), style = Stroke(3 * density, cap = StrokeCap.Round))
        } else {
            drawPath(path, Accent.copy(alpha = 0.14f), style = Stroke(8 * density, cap = StrokeCap.Round))
            drawPath(path, Accent.copy(alpha = 0.25f), style = Stroke(4 * density, cap = StrokeCap.Round))
        }
    }

    /** The line itself, its start ring and its beads. */
    fun drawLine(scope: DrawScope, f: Frame) = with(scope) {
        val line = 1.4f * density
        legs(f) { a, b, front ->
            drawLine(ThreadColor.copy(alpha = (0.45 + 0.5 * front).toFloat()), a, b, strokeWidth = line, cap = StrokeCap.Round)
        }
        val pts = f.points
        // A ring round the tapped person, so the line's start is clear even before their face comes round.
        if (f.ringsStart) {
            val start = pts[0]
            drawCircle(Accent.copy(alpha = 0.9f), radius = 13 * density, center = Offset(start.x.toFloat(), start.y.toFloat()),
                style = Stroke(2 * density))
        }
        // A bead on each link reached, so the layers it passes are clear.
        val reached = f.progress * (pts.size - 1)
        for (i in (if (f.ringsStart) 1 else 0) until pts.size - 1) {
            if (i > reached) break
            val p = pts[i]
            drawCircle(Accent.copy(alpha = (0.6 + 0.4 * p.front).toFloat()), radius = 2.6f * density,
                center = Offset(p.x.toFloat(), p.y.toFloat()))
        }
    }
}
