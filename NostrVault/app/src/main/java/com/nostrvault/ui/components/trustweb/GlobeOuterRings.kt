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
 * 4 about 60%, 5 about 35%), and its label where the ring crosses the screen.
 * Faint, with no dots, when there is no rank. The rings sit round the middle
 * of the screen and grow with the camera's zoom, so they stay outside the
 * globe. Picking a hop turns its ring into a sphere of its own
 * ([GlobeHopSphere], placed by [spheres]) round the nested inner globe.
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
     * sphere of its own ([spheres]), so its flat circle and dots fade out as
     * [GlobeRingZoom.sphere] comes in. Only the hop label stays, on the sphere's top.
     */
    fun draw(
        scope: DrawScope, outer: TrustMapOuter, zoom: Double, phone: Boolean, measurer: TextMeasurer,
        level: Double = 0.0,
    ) = with(scope) {
        if (outer.rings.isEmpty()) return@with
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        val base = outline(w, h, zoom, phone)
        if (!base.isFinite()) return@with
        val mid = Offset(size.width / 2, size.height / 2)
        val faint = outer.isFaint
        val dash = if (faint) PathEffect.dashPathEffect(floatArrayOf(3 * density, 6 * density)) else null
        for (ring in outer.rings) {
            val shown = GlobeRingZoom.visibility(ring.hop, level).toFloat()
            if (shown <= 0.01f) continue
            val picked = GlobeRingZoom.emphasis(ring.hop, level).toFloat()
            val flat = if (faint) 1f else 1 - GlobeRingZoom.sphere(ring.hop, level).toFloat()
            val r = place(ring.hop, level, base)
            val fade = (if (faint) 1f else fadeFor(ring.hop, picked)) * shown
            if (flat > 0.01f) {
                drawCircle(
                    color = HazeColor.copy(alpha = ((if (faint) 0.10f else 0.28f * maxOf(fade, 0.5f * shown)) * flat).coerceAtMost(1f)),
                    radius = r.toFloat(), center = mid,
                    style = Stroke(width = (if (faint) 0.8f else 1.1f) * density, pathEffect = dash),
                )
                if (!faint) {
                    val dot = 1.6f * density
                    val color = MutualStar.copy(alpha = (0.75f * fade * flat).coerceAtMost(1f))
                    for (key in ring.top) {
                        val a = angle(key)
                        drawCircle(color, radius = dot, center = Offset((mid.x + r * cos(a)).toFloat(), (mid.y + r * sin(a)).toFloat()))
                    }
                }
            }
            // A ring nested inside a later pick loses its label.
            val nested = GlobeRingZoom.inside(ring.hop, level).toFloat()
            if (nested < 0.99f) labelPoint(r, mid, w, density)?.let { label ->
                val layout = measurer.measure(
                    if (faint) "${ring.hop} hops" else TrustMapOuter.chipText(ring),
                    TextStyle(fontSize = (10 + 2 * picked).sp, fontWeight = FontWeight.SemiBold,
                        color = GlobeLabel.copy(alpha = (if (faint) 0.35f else 0.7f * maxOf(fade, 0.5f)) * shown * (1 - nested))),
                )
                drawText(layout, topLeft = Offset(label.x - layout.size.width, label.y - layout.size.height))
            }
        }
    }

    /**
     * The picked hop's sphere, and any picked before it now nested inside it,
     * inner first so the picked one is drawn over what is nested in it; and
     * the nested inner globe's disc (centre x, y, radius), with room for its
     * outer shell's faces. Empty at your circle.
     */
    fun spheres(
        outer: TrustMapOuter, w: Double, h: Double, zoom: Double, phone: Boolean, level: Double,
    ): Pair<List<GlobeHopSphere.Placed>, Triple<Double, Double, Double>?> {
        if (level <= 0.001 || outer.isFaint) return Pair(emptyList(), null)
        val base = outline(w, h, zoom, phone)
        if (!base.isFinite()) return Pair(emptyList(), null)
        val mid = Offset((w / 2).toFloat(), (h / 2).toFloat())
        val globe = place(TrustMapOuter.FIRST_HOP - 1, level, base)
        val hole = Triple(w / 2, h / 2, globe * HOLE_REACH)
        val out = ArrayList<GlobeHopSphere.Placed>()
        for (ring in outer.rings) {
            val shown = GlobeRingZoom.visibility(ring.hop, level) * GlobeRingZoom.sphere(ring.hop, level)
            if (shown <= 0.01) continue
            val picked = GlobeRingZoom.emphasis(ring.hop, level)
            out += GlobeHopSphere.Placed(ring, mid, place(ring.hop, level, base), shown * fadeFor(ring.hop, picked.toFloat()), picked)
        }
        return Pair(out, hole)
    }

    /** The nested globe's faces reach past its outline to its outer shells ([TrustMap.OUTER_RADIUS]). */
    private const val HOLE_REACH = GlobeHopSphere.HOLE_REACH

    /** A ring's radius at [level], shrunk when it is nested inside the picked one. Every ring stays centred. */
    private fun place(hop: Int, level: Double, base: Double): Double {
        val r = if (hop < TrustMapOuter.FIRST_HOP) GlobeRingZoom.innerOutline(level, base) else GlobeRingZoom.radius(hop, level, base)
        return r * GlobeRingZoom.nest(hop, level)
    }

    /** The picked ring comes up to full strength, whatever its hop. */
    private fun fadeFor(hop: Int, picked: Float): Float {
        val ringFade = TrustMapOuter.fade(hop)
        return ringFade + (1 - ringFade) * picked
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
}
