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
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Draws the globe's outer rings ([TrustMapOuter]) behind the stars: one
 * circle per hop past your circle, a dot on it for each of its best-ranked
 * people, and its hop count where the ring crosses the screen. Faint, with
 * no dots, when there is no rank. The rings sit round the middle of the
 * screen and grow with the camera's zoom, so they stay outside the globe.
 * iOS `Views/TrustWeb/GlobeOuterRings.swift`.
 */
internal object GlobeOuterRings {
    /** Ring radius against the inner globe's outline, for the first outer hop; each hop after sits [STEP] further out. */
    const val FIRST = 1.72
    const val STEP = 0.26

    /** The inner globe's outline radius on screen ([GlobeCamera.unit]). */
    fun outline(w: Double, h: Double, zoom: Double, phone: Boolean): Double {
        val r = TrustMap.RING_RADIUS
        val d = GlobeCamera.DISTANCE / zoom
        if (d <= r) return Double.POSITIVE_INFINITY
        return GlobeCamera.unit(w, h, phone) * r / sqrt(d * d - r * r)
    }

    fun radius(hop: Int, outline: Double): Double = outline * (FIRST + STEP * (hop - TrustMapOuter.FIRST_HOP))

    /** Where on its circle a person's dot sits: from their key, so it never moves. */
    fun angle(pubkey: String): Double {
        var head = 0L
        for (c in pubkey.take(8)) head = head * 31 + c.code
        return Math.floorMod(head, 3600L) / 3600.0 * 2 * Math.PI
    }

    fun draw(scope: DrawScope, outer: TrustMapOuter, zoom: Double, phone: Boolean, measurer: TextMeasurer) = with(scope) {
        if (outer.rings.isEmpty()) return@with
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        val base = outline(w, h, zoom, phone)
        if (!base.isFinite()) return@with
        val mid = Offset(size.width / 2, size.height / 2)
        val faint = outer.isFaint
        val dash = if (faint) PathEffect.dashPathEffect(floatArrayOf(3.dp2px(density), 6.dp2px(density))) else null
        for (ring in outer.rings) {
            val r = radius(ring.hop, base)
            drawCircle(
                color = HazeColor.copy(alpha = if (faint) 0.10f else 0.28f),
                radius = r.toFloat(), center = mid,
                style = Stroke(width = (if (faint) 0.8f else 1.1f) * density, pathEffect = dash),
            )
            if (!faint) {
                for (key in ring.top) {
                    val a = angle(key)
                    drawCircle(MutualStar.copy(alpha = 0.75f), radius = 1.6f * density,
                        center = Offset((mid.x + r * cos(a)).toFloat(), (mid.y + r * sin(a)).toFloat()))
                }
            }
            labelPoint(r, mid, w, density)?.let { at ->
                val layout = measurer.measure(
                    if (faint) "${ring.hop} hops" else TrustMapOuter.chipText(ring),
                    TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
                        color = GlobeLabel.copy(alpha = if (faint) 0.35f else 0.7f)),
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
