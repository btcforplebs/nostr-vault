package com.nostrvault.ui.components

import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import com.nostrvault.ui.components.GlobeScene.Companion.LEVELS
import com.nostrvault.ui.components.GlobeScene.Slot

// GlobeScene's drawing: what goes under the faces, and the names over them. Split out of GlobeScene.kt.

    /** Stars, threads, glows and embers: everything under the faces. */
    internal fun GlobeScene.drawBack(scope: DrawScope, accent: Color) = with(scope) {
        prepare(size.width, size.height, density)
        if (!ready) return@with
        val dp = dpPx

        // Glow behind the core.
        val glowR = (coreR * 3).toFloat()
        if (glowR > 0f) {
            drawCircle(
                brush = Brush.radialGradient(listOf(accent.copy(alpha = 0.32f), Color.Transparent),
                    center = Offset(originX.toFloat(), originY.toFloat()), radius = glowR),
                radius = glowR,
                center = Offset(originX.toFloat(), originY.toFloat()),
            )
        }

        fun fill(slot: Slot, color: Color) {
            if (lite) {
                drawIntoCanvas { canvas ->
                    for (bucket in pointOrder) {
                        if (bucket.slot != slot || bucket.count == 0) continue
                        pointPaint.color = color.copy(alpha = bucket.level.toFloat() / LEVELS).toArgb()
                        pointPaint.strokeWidth = bucket.diameter
                        canvas.nativeCanvas.drawPoints(bucket.xy, 0, bucket.count * 2, pointPaint)
                    }
                }
                return
            }
            for (level in 1..LEVELS) {
                val path = buckets[slot.ordinal][level]
                if (!path.isEmpty) drawPath(path, color.copy(alpha = level.toFloat() / LEVELS))
            }
        }
        fill(Slot.HAZE, HazeColor)
        fill(Slot.RING, RingColor)
        fill(Slot.MUTUAL, Color.White)

        // Glow brightens toward the front. No blur on every Android version,
        // so two soft strokes stand in for iOS's blurred layer.
        fun bandAlpha(level: Int): Float {
            val front = (level + 0.5f) / 4
            return 0.10f + 0.75f * front * front
        }
        for (level in 0 until 4) {
            if (glow[level].isEmpty) continue
            val a = bandAlpha(level) * 0.6f
            drawPath(glow[level], accent.copy(alpha = a * 0.25f), style = Stroke(width = 8 * dp, cap = StrokeCap.Round))
            drawPath(glow[level], accent.copy(alpha = a * 0.45f), style = Stroke(width = 4 * dp, cap = StrokeCap.Round))
        }
        for (level in 0 until 4) {
            val a = bandAlpha(level)
            if (!faint[level].isEmpty) drawPath(faint[level], ThreadColor.copy(alpha = a * 0.45f), style = Stroke(width = 0.8f * dp))
            if (!strong[level].isEmpty) drawPath(strong[level], ThreadColor.copy(alpha = a), style = Stroke(width = 1.3f * dp))
        }
        if (!dashed.isEmpty) {
            drawPath(dashed, ThreadColor.copy(alpha = 0.7f), style = Stroke(width = 1.2f * dp, cap = StrokeCap.Round,
                join = StrokeJoin.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * dp, 4 * dp))))
        }
        fill(Slot.HOT, accent)

        // A soft tint behind each face, and embers for those behind the globe.
        for (spot in spots) {
            val c = Offset(spot.x.toFloat(), spot.y.toFloat())
            if (spot.ember) {
                drawCircle(accent.copy(alpha = spot.alpha.toFloat().coerceIn(0f, 1f)), radius = spot.r.toFloat(), center = c)
                continue
            }
            val r = spot.r.toFloat()
            if (r <= 0f) continue
            drawCircle(
                brush = Brush.radialGradient(
                    0.6f / 1.9f to spot.tint.copy(alpha = 0.35f * spot.alpha.toFloat()),
                    1f to Color.Transparent,
                    center = c, radius = r * 1.9f,
                ),
                radius = r * 1.9f,
                center = c,
            )
        }
    }

    /** Names under the faces, the core, and plain stars once zoomed in. */
    internal fun GlobeScene.drawLabels(scope: DrawScope, measurer: TextMeasurer, name: (String) -> String) = with(scope) {
        prepare(size.width, size.height, density)
        if (!ready) return@with
        val dp = dpPx
        fun label(text: String, x: Double, y: Double, sizeSp: Float, weight: FontWeight, alpha: Float) {
            val layout = measurer.measure(
                text,
                TextStyle(color = Color.White, fontSize = sizeSp.sp, fontWeight = weight),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                constraints = Constraints(maxWidth = (120 * dp).roundToInt()),
            )
            drawText(layout, topLeft = Offset((x - layout.size.width / 2.0).toFloat(), (y - layout.size.height / 2.0).toFloat()),
                alpha = alpha.coerceIn(0f, 1f))
        }
        for (spot in spots) {
            if (spot.core || spot.ember || !spot.label) continue
            val isAuthor = spot.key == (traceTarget ?: author)
            label(name(spot.key), spot.x, spot.y + spot.r + 10 * dp, if (isAuthor) 14f else 11f, FontWeight.SemiBold,
                (0.9 * spot.alpha).toFloat())
        }
        for (star in starLabels) {
            label(name(star.key), star.x, star.y + star.r + 8 * dp, 10f, FontWeight.Normal, (0.6 * star.alpha).toFloat())
        }
        spots.lastOrNull()?.takeIf { it.core }?.let { core ->
            label(name(core.key), core.x, core.y + core.r + 11 * dp, 13f, FontWeight.Bold, 1f)
        }
    }
