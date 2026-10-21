package com.nostrvault.ui.screens.profile

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.ZapOrange
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

/**
 * The confirmation that a profile zap went out, on the zap button itself:
 * a soft glow, an expanding ring and a small scatter of sparks, all driven
 * by one spring from 0 to 1. Port of iOS `ZapBurstView` (Components/
 * ZapBurstView.swift). Nothing is drawn between zaps; each one mounts a
 * fresh burst, so it always plays from the start, even over the last one.
 * Under Reduce Motion there is none, as on iOS.
 *
 * Give it the button's bounds (`matchParentSize` in a Box with the button):
 * it centres its 44dp square on them, drawing past them, and takes no taps.
 */
@Composable
internal fun ProfileZapBurst(bursts: Flow<Unit>, modifier: Modifier = Modifier) {
    var burstId by remember { mutableIntStateOf(0) }
    var showing by remember { mutableIntStateOf(0) }
    LaunchedEffect(bursts) {
        bursts.collect {
            if (!Motion.isReduced) {
                burstId += 1
                showing = burstId
            }
        }
    }
    if (showing > 0) {
        key(showing) {
            Burst(onDone = { if (showing == it) showing = 0 }, id = showing, modifier = modifier)
        }
    }
}

/** One play of the burst, from mount to fully faded (iOS `Burst`). */
@Composable
private fun Burst(id: Int, onDone: (Int) -> Unit, modifier: Modifier) {
    val progress = remember { Animatable(0f) }
    val sparks = remember { ZapBurstSparks.make() }
    LaunchedEffect(Unit) {
        // iOS Motion.zapBurst: spring(response 0.46, damping 0.72).
        progress.animateTo(1f, Motion.custom(responseMs = 460, damping = 0.72f))
    }
    LaunchedEffect(Unit) {
        // Unmount once the spring has settled; a newer burst keeps its own.
        delay(800)
        onDone(id)
    }
    Box(modifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.wrapContentSize(unbounded = true).requiredSize(ZapBurstSparks.FRAME_DP.dp)) {
            val p = progress.value
            val radius = size.minDimension / 2
            // Glow: a radial fade out to 20pt in a 22pt circle, scaled.
            val glowScale = 0.5f + p * 0.9f
            val glowAlpha = ZapBurstSparks.glowOpacity(p)
            if (glowAlpha > 0f) {
                drawCircle(
                    Brush.radialGradient(
                        0f to ZapOrange.copy(alpha = glowAlpha),
                        (20f / 22f) to ZapOrange.copy(alpha = 0f),
                        center = center,
                        radius = radius * glowScale,
                    ),
                    radius = radius * glowScale,
                )
            }
            // Ring: SwiftUI scales the stroke with the circle, so the line does too.
            val ringScale = 0.55f + p * 1.35f
            val ringAlpha = (0.75f * (1 - p)).coerceIn(0f, 1f)
            if (ringAlpha > 0f) {
                drawCircle(
                    ZapOrange.copy(alpha = ringAlpha),
                    radius = radius * ringScale,
                    style = Stroke(width = 1.25.dp.toPx() * ringScale),
                )
            }
            val sparkAlpha = (1 - p).coerceIn(0f, 1f)
            if (sparkAlpha > 0f) sparks.forEach { spark ->
                drawCircle(
                    ZapOrange.copy(alpha = sparkAlpha),
                    radius = spark.sizeDp.dp.toPx() / 2,
                    center = center + Offset(
                        (cos(spark.angle) * spark.distanceDp.dp.toPx() * p).toFloat(),
                        (sin(spark.angle) * spark.distanceDp.dp.toPx() * p).toFloat(),
                    ),
                )
            }
        }
    }
}

/** The burst's numbers, from iOS `ZapBurstView`. */
internal object ZapBurstSparks {
    const val FRAME_DP = 44f

    class Spark(val angle: Double, val distanceDp: Float, val sizeDp: Float)

    /** Six sparks round the circle, each nudged off its spoke a little. */
    fun make(count: Int = 6, random: Random = Random): List<Spark> = (0 until count).map { i ->
        val base = i.toDouble() / count * 2 * Math.PI
        Spark(
            angle = base + random.nextDouble(-0.28, 0.28),
            distanceDp = random.nextDouble(16.0, 24.0).toFloat(),
            sizeDp = random.nextDouble(2.5, 4.0).toFloat(),
        )
    }

    /** Fast in, fast out: a beat of light rather than a lingering glow. */
    fun glowOpacity(p: Float): Float =
        (if (p < 0.2f) p / 0.2f * 0.5f else 0.5f * (1 - (p - 0.2f) / 0.8f)).coerceIn(0f, 1f)
}
