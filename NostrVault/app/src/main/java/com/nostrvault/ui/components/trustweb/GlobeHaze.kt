package com.nostrvault.ui.components

import android.graphics.Paint
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.toArgb
import com.nostrvault.data.model.GlobeHazeField
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter

/**
 * Paints a zoomed-out ring's haze ([GlobeHazeField]): the people ranked after
 * its top 300, as faint dots round the ring's centre, the best nearest it.
 * The positions are worked out once per ring into one unit-space FloatArray;
 * each frame only scales the canvas to the ring's radius and makes two
 * native drawPoints calls (the brighter better half, the fainter rest), with
 * no per-dot objects. Never tapped: [GlobeScene.hit] only looks at the
 * globe's faces. A lite phone draws the best [TrustMap.HAZE_CAP_LITE].
 * iOS `Views/TrustWeb/GlobeHaze.swift`.
 */
internal object GlobeHaze {
    /** A haze dot's radius in dp, at the fitted ring. */
    const val DOT = 1.0f
    /** How strongly the better and the lower half are drawn, at full zoom. */
    const val ALPHA_BEST = 0.42f
    const val ALPHA_REST = 0.24f

    private class Built(val keys: List<String>, val points: FloatArray)

    /** One per hop; the canvas draws on the main thread only. */
    private val built = HashMap<Int, Built>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND }

    /**
     * Draws [ring]'s haze at [alpha] (0 to 1, the ring's emphasis) round [mid]
     * at radius [r] px. [ref] is the fitted ring's radius, where a dot is [DOT]
     * dp across its radius.
     */
    fun draw(scope: DrawScope, ring: TrustMapOuter.Ring, alpha: Float, mid: Offset, r: Double, ref: Double, lite: Boolean) {
        if (alpha <= 0.01f || ring.haze.isEmpty() || r <= 1 || ref <= 1) return
        val points = points(ring)
        val count = if (lite) minOf(ring.haze.size, TrustMap.HAZE_CAP_LITE) else ring.haze.size
        val half = count / 2
        val star = MutualStar
        scope.drawIntoCanvas { c ->
            val canvas = c.nativeCanvas
            canvas.save()
            canvas.translate(mid.x, mid.y)
            canvas.scale(r.toFloat(), r.toFloat())
            // Unit space: a dot DOT dp across at the fitted ring, growing with it.
            paint.strokeWidth = (2 * DOT * scope.density / ref).toFloat()
            paint.color = star.copy(alpha = ALPHA_BEST * alpha).toArgb()
            canvas.drawPoints(points, 0, half * 2, paint)
            paint.color = star.copy(alpha = ALPHA_REST * alpha).toArgb()
            canvas.drawPoints(points, half * 2, (count - half) * 2, paint)
            canvas.restore()
        }
    }

    private fun points(ring: TrustMapOuter.Ring): FloatArray {
        // A ring's keys come from one TrustMapOuter, so this is a reference check first.
        built[ring.hop]?.let { if (it.keys === ring.haze || it.keys == ring.haze) return it.points }
        val b = Built(ring.haze, GlobeHazeField.positions(ring.haze))
        built[ring.hop] = b
        return b.points
    }
}
