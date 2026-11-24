package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.drawText
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.GlobeCamera
import com.nostrvault.data.model.GlobeRingZoom
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Draws the globe's outer rings ([TrustMapOuter]) behind the stars: one
 * circle per hop past your circle, a dot on it for each of its best-ranked
 * people (the globe list's top 300), fainter the further out (hop 3 full,
 * 4 about 60%, 5 about 35%), and its label where the ring crosses the screen. Faint, with
 * no dots, when there is no rank. The rings sit round the middle of the
 * screen and grow with the camera's zoom, so they stay outside the globe.
 * iOS `Views/TrustWeb/GlobeOuterRings.swift`.
 */
internal object GlobeOuterRings {
    /** The inner globe's outline radius on screen ([GlobeCamera.unit]). */
    fun outline(w: Double, h: Double, zoom: Double, phone: Boolean): Double {
        val r = TrustMap.RING_RADIUS
        val d = GlobeCamera.DISTANCE / zoom
        if (d <= r) return Double.POSITIVE_INFINITY
        return GlobeCamera.unit(w, h, phone) * r / sqrt(d * d - r * r)
    }

    /** Where on its circle a person's dot sits: from their key, so it never moves. */
    fun angle(pubkey: String): Double {
        var head = 0L
        for (c in pubkey.take(8)) head = head * 31 + c.code
        return Math.floorMod(head, 3600L) / 3600.0 * 2 * Math.PI
    }

    /**
     * [level] is how far a Hop layer has zoomed out ([GlobeRingZoom]): 0 draws
     * the rings round the full globe; past it the picked ring fills the frame,
     * the rings inside it close in on the shrunk globe, and the picked ring's
     * people get a line to their link one ring in.
     */
    fun draw(scope: DrawScope, outer: TrustMapOuter, zoom: Double, phone: Boolean, measurer: TextMeasurer, level: Double = 0.0) = with(scope) {
        if (outer.rings.isEmpty()) return@with
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        val base = outline(w, h, zoom, phone)
        if (!base.isFinite()) return@with
        val mid = Offset(size.width / 2, size.height / 2)
        val half = min(w, h) / 2
        val faint = outer.isFaint
        val dash = if (faint) PathEffect.dashPathEffect(floatArrayOf(3.dp2px(density), 6.dp2px(density))) else null
        fun radius(hop: Int): Double =
            if (hop < TrustMapOuter.FIRST_HOP) GlobeRingZoom.innerOutline(level, base)
            else GlobeRingZoom.radius(hop, level, base, half)
        fun point(key: String, r: Double): Offset {
            val a = angle(key)
            return Offset((mid.x + r * cos(a)).toFloat(), (mid.y + r * sin(a)).toFloat())
        }
        for (ring in outer.rings) {
            val shown = GlobeRingZoom.visibility(ring.hop, level).toFloat()
            if (shown <= 0.01f) continue
            val picked = GlobeRingZoom.emphasis(ring.hop, level).toFloat()
            val r = radius(ring.hop)
            // The picked ring comes up to full strength, whatever its hop.
            val ringFade = TrustMapOuter.fade(ring.hop)
            val fade = (if (faint) 1f else ringFade + (1 - ringFade) * picked) * shown
            drawCircle(
                color = HazeColor.copy(alpha = ((if (faint) 0.10f else 0.28f * maxOf(fade, 0.5f * shown)) + 0.14f * picked).coerceAtMost(1f)),
                radius = r.toFloat(), center = mid,
                style = Stroke(width = ((if (faint) 0.8f else 1.1f) + 0.5f * picked) * density, pathEffect = dash),
            )
            if (!faint) {
                if (picked > 0.01f) {
                    // Lines from the picked ring's best to who links them in: on
                    // the ring inside, or for Hop 3 on the shrunk globe's edge.
                    // Faint and capped so they read as threads, not a fan.
                    val inner = radius(ring.hop - 1)
                    val lines = Path()
                    for (key in ring.top.take(GlobeRingZoom.MAX_LINKS)) {
                        val via = ring.via[key] ?: continue
                        val from = point(key, r)
                        val to = point(via, inner)
                        lines.moveTo(from.x, from.y)
                        lines.lineTo(to.x, to.y)
                    }
                    drawPath(lines, HazeColor.copy(alpha = 0.12f * picked), style = Stroke(width = 0.6f * density))
                }
                val dot = 1.6f * (1 + 0.5f * picked) * density
                for (key in ring.top) {
                    drawCircle(MutualStar.copy(alpha = 0.75f * fade), radius = dot, center = point(key, r))
                }
            }
            labelPoint(r, mid, w, density)?.let { at ->
                val layout = measurer.measure(
                    if (faint) "${ring.hop} hops" else TrustMapOuter.chipText(ring),
                    TextStyle(fontSize = (10 + 2 * picked).sp, fontWeight = FontWeight.SemiBold,
                        color = GlobeLabel.copy(alpha = (if (faint) 0.35f else 0.7f * maxOf(fade, 0.6f)) * shown)),
                )
                drawText(layout, topLeft = Offset(at.x - layout.size.width, at.y - layout.size.height))
            }
        }
    }

    /** Up and to the right on the ring, where it is still on screen and clear of the status bar and the WOT tab's top bar. */
    private fun labelPoint(r: Double, mid: Offset, w: Double, density: Float): Offset? {
        val inset = 14.0 * density
        val dx = min(r * 0.5, w / 2 - inset)
        if (dx <= 0 || r <= dx) return null
        val y = mid.y - sqrt(r * r - dx * dx) - 3 * density
        if (y <= 120 * density) return null
        return Offset((mid.x + dx).toFloat(), y.toFloat())
    }

    private fun Int.dp2px(density: Float) = this * density
}
