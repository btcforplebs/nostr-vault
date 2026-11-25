package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.drawText
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.GlobeCamera
import com.nostrvault.data.model.GlobeHazeField
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
    fun angle(pubkey: String): Double = GlobeHazeField.hash(pubkey).first

    /**
     * [level] is how far a Hop layer has zoomed out ([GlobeRingZoom]): 0 draws
     * the rings flat round the full globe. Past it the picked ring becomes a
     * sphere of its own ([GlobeHopSphere]), so its flat circle and dots fade
     * out as [GlobeRingZoom.sphere] comes in; the rings past it stay round it.
     * A ring nested inside the picked one loses its label.
     */
    fun draw(scope: DrawScope, outer: TrustMapOuter, zoom: Double, phone: Boolean, measurer: TextMeasurer, level: Double = 0.0) = with(scope) {
        if (outer.rings.isEmpty()) return@with
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        val base = outline(w, h, zoom, phone)
        if (!base.isFinite()) return@with
        val grow = pinch(w, h, zoom, phone)
        val faint = outer.isFaint
        val dash = if (faint) PathEffect.dashPathEffect(floatArrayOf(3.dp2px(density), 6.dp2px(density))) else null
        for (ring in outer.rings) {
            val shown = GlobeRingZoom.visibility(ring.hop, level).toFloat()
            if (shown <= 0.01f) continue
            val picked = GlobeRingZoom.emphasis(ring.hop, level).toFloat()
            val flat = if (faint) 1f else 1 - GlobeRingZoom.sphere(ring.hop, level).toFloat()
            val at = place(ring.hop, level, base, w, h, grow)
            val r = at.r
            val fade = (if (faint) 1f else fadeFor(ring.hop, picked)) * shown
            if (flat > 0.01f) {
                drawCircle(
                    color = HazeColor.copy(alpha = ((if (faint) 0.10f else 0.28f * maxOf(fade, 0.5f * shown)) * flat).coerceAtMost(1f)),
                    radius = r.toFloat(), center = at.centre,
                    style = Stroke(width = (if (faint) 0.8f else 1.1f) * density, pathEffect = dash),
                )
                if (!faint) {
                    val dot = 1.6f * density
                    val color = MutualStar.copy(alpha = 0.75f * fade * flat)
                    for (key in ring.top) {
                        val a = angle(key)
                        drawCircle(color, radius = dot, center = Offset((at.centre.x + r * cos(a)).toFloat(), (at.centre.y + r * sin(a)).toFloat()))
                    }
                }
            }
            val nested = GlobeRingZoom.inside(ring.hop, level).toFloat()
            if (nested >= 0.99f) continue
            labelPoint(r, at.centre, w, density)?.let { label ->
                val layout = measurer.measure(
                    if (faint) "${ring.hop} hops" else TrustMapOuter.chipText(ring),
                    TextStyle(fontSize = (10 + 2 * picked).sp, fontWeight = FontWeight.SemiBold,
                        color = GlobeLabel.copy(alpha = (if (faint) 0.35f else 0.7f * maxOf(fade, 0.6f)) * shown * (1 - nested))),
                )
                drawText(layout, topLeft = Offset(label.x - layout.size.width, label.y - layout.size.height))
            }
        }
    }

    /** A ring's centre and radius at [level], shrunk when it is nested inside the picked one. Hop 2 is the inner globe's outline. */
    fun place(hop: Int, level: Double, base: Double, w: Double, h: Double, grow: Double): Place {
        val r = if (hop < TrustMapOuter.FIRST_HOP) GlobeRingZoom.innerOutline(level, base)
            else GlobeRingZoom.radius(hop, level, base, min(w, h) / 2, grow)
        return Place(Offset((w / 2).toFloat(), (h / 2).toFloat()), r * GlobeRingZoom.nest(hop, level))
    }

    /**
     * How far a pinch has zoomed the whole nested view in: the inner globe's
     * outline against its size at zoom 1, so the picked sphere and everything
     * nested in it grow together (Logen 2026-11-25).
     */
    fun pinch(w: Double, h: Double, zoom: Double, phone: Boolean): Double {
        val at1 = outline(w, h, 1.0, phone)
        val now = outline(w, h, zoom, phone)
        return if (at1.isFinite() && now.isFinite() && at1 > 0) now / at1 else 1.0
    }

    /** The picked ring comes up to full strength, whatever its hop. */
    fun fadeFor(hop: Int, picked: Float): Float {
        val ringFade = TrustMapOuter.fade(hop)
        return ringFade + (1 - ringFade) * picked
    }

    /** A ring's centre on screen and its radius in px. */
    class Place(val centre: Offset, val r: Double)

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
