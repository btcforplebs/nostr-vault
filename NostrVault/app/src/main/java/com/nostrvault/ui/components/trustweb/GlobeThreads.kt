package com.nostrvault.ui.components

import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.Stroke
import com.nostrvault.data.model.GlobeEdge
import kotlin.math.max
import kotlin.math.min

/**
 * The threads' brightness steps, front to back (iOS `GlobeScene.threadBands`
 * and the band functions in `GlobeScene.draw`). Fine bands, and a glow that
 * ramps in over several of them, so a thread turning toward the rim dims in
 * small steps and never pops.
 */
internal object GlobeThreads {
    const val BANDS = 12
    /** The glow's stroke and blur, in dp (iOS points). */
    const val GLOW_WIDTH = 3f
    const val GLOW_BLUR = 5f
    const val FAINT_WIDTH = 0.8f
    const val STRONG_WIDTH = 1.3f
    /** Glow strokes this faint are skipped (iOS `glowAlpha > 0.01`). */
    const val GLOW_MIN = 0.01

    /** Which band a thread through a star [front] of the way forward goes in. */
    fun band(front: Double) = min(BANDS - 1, max(0, (front * BANDS).toInt()))

    /** The middle of band [level], 0 at the back to 1 at the front. */
    fun bandFront(level: Int) = (level + 0.5) / BANDS

    /** A thread's opacity in band [level]; the faint inner leg is 0.45 of it. */
    fun bandAlpha(level: Int): Double {
        val front = bandFront(level)
        return 0.10 + 0.75 * front * front
    }

    /** The glow's opacity in band [level]: none toward the back, ramping in toward the front. */
    fun glowAlpha(level: Int) = bandAlpha(level) * 0.6 * GlobeEdge.smoothstep(0.45, 0.8, bandFront(level))

    /** The glow layer's blur for [dp] pixels per dp. Decal: the glow fades out past its lines, never smears to the edge. */
    fun glowBlur(dp: Float): RenderEffect = BlurEffect(GLOW_BLUR * dp, GLOW_BLUR * dp, TileMode.Decal)

    /** Every stroke the threads use, at one density. */
    class Strokes(val dp: Float) {
        val glow = Stroke(width = GLOW_WIDTH * dp)
        /** Where no blur is available: two soft strokes stand in for it. */
        val softWide = Stroke(width = 8 * dp, cap = StrokeCap.Round)
        val softNarrow = Stroke(width = 4 * dp, cap = StrokeCap.Round)
        val faint = Stroke(width = FAINT_WIDTH * dp)
        val strong = Stroke(width = STRONG_WIDTH * dp)
        val dashed = Stroke(width = 1.2f * dp, cap = StrokeCap.Round, join = StrokeJoin.Round,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * dp, 4 * dp)))
    }

    /** Built once per density, so a frame draws the threads with no new strokes. Main thread only. */
    private var strokes: Strokes? = null

    fun strokes(dp: Float): Strokes = strokes?.takeIf { it.dp == dp } ?: Strokes(dp).also { strokes = it }
}
