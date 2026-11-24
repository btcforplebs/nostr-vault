package com.nostrvault.data.model

import kotlin.math.floor
import kotlin.math.min

/**
 * The WOT tab's Hop 3, Hop 4 and Hop 5 layers zoom your own globe out to
 * that outer ring: the inner spheres shrink toward the middle and fade, the
 * rings inside the picked one close up around them, and the picked ring
 * grows to fill the frame (Logen 2026-11-24, "best visual effort").
 *
 * `level` is a continuous zoom: 0 is your circle (Everyone, Following,
 * Vouched), 1 is Hop 3, 2 is Hop 4, 3 is Hop 5. The globe eases it from pick
 * to pick, so every value in between is drawn and it animates both ways.
 * iOS `Models/GlobeRingZoom.swift`.
 */
object GlobeRingZoom {
    /** Ring radius against the inner globe's outline at level 0, for the first outer hop. */
    const val FIRST = 1.72
    /** Each hop after the first sits this much further out at level 0. */
    const val STEP = 0.26

    /** The deepest level: Hop 5. */
    const val MAX_LEVEL = 3

    /** How big the inner globe is drawn at each whole level. */
    val INNER_SCALES = doubleArrayOf(1.0, 0.36, 0.25, 0.18)
    /** How strongly the inner globe is drawn at each whole level: faded, never gone. */
    val INNER_ALPHAS = doubleArrayOf(1.0, 0.6, 0.5, 0.42)
    /** The picked ring's radius as a share of half the frame's short side. */
    const val FIT = 0.84
    /** Rings inside the picked one are drawn this strongly. */
    const val INSIDE_ALPHA = 0.6
    /**
     * At most this many of the picked ring's people get a line to their link one
     * ring in. 120 drew a web of chords right across the ring and over the shrunk
     * globe (a via's place on its ring has nothing to do with yours), so only the
     * best 40 get one, faint.
     */
    const val MAX_LINKS = 40

    // ── Sink (Logen 2026-11-24) ──

    /**
     * Everything inside the picked ring (the inner globe, and the rings between
     * it and the picked one) sinks down and gets smaller, so it reads as pulling
     * back into space; the picked ring and its haze ([GlobeHazeField]) stay
     * centred. How far down, as a share of half the frame's short side, at each
     * whole level.
     */
    val SINK_DROPS = doubleArrayOf(0.0, 0.34, 0.36, 0.38)
    /** How much smaller what sinks is drawn, on top of [INNER_SCALES]. */
    val SINK_SCALES = doubleArrayOf(1.0, 0.8, 0.74, 0.68)

    /** Where a ring is drawn: its centre [drop] px below the frame's middle, at [scale] times its radius. */
    data class Sink(val drop: Double, val scale: Double)

    /** How much [hop]'s ring sinks (0 to 1): the inner globe (hop 2 and in) once any hop is picked, an outer ring once a hop past it is. */
    fun inside(hop: Int, level: Double): Double = blend(level) { if (it > 0 && hop < TrustMapOuter.FIRST_HOP + it - 1) 1.0 else 0.0 }

    /** Where [hop]'s ring is drawn at [level]; [half] is half the frame's short side. */
    fun sink(hop: Int, level: Double, half: Double): Sink {
        val a = inside(hop, level)
        return Sink(a * lerp(SINK_DROPS, level) * half, 1 - a * (1 - lerp(SINK_SCALES, level)))
    }

    /** The inner globe's sink at [level] in a [w] x [h] frame. */
    fun innerSink(level: Double, w: Double, h: Double): Sink = sink(TrustMapOuter.FIRST_HOP - 1, level, min(w, h) / 2)

    /** The inner globe's whole drawn scale at [level]: [innerScale] times its sink. */
    fun innerDrawScale(level: Double, w: Double, h: Double): Double = innerScale(level) * innerSink(level, w, h).scale

    /**
     * How much past the frame (as a share of its size, each side) the shrunk and
     * sunk inner globe still lands on screen: its stars there must be kept.
     */
    fun cullGrow(level: Double, w: Double, h: Double): Double {
        val s = innerDrawScale(level, w, h)
        return (1 / s - 1) / 2 + innerSink(level, w, h).drop / s / min(w, h)
    }

    /** A tap at ([x], [y]) on screen, in the inner globe's own unshrunk, unsunk frame. */
    fun unsink(x: Float, y: Float, w: Float, h: Float, level: Double): Pair<Float, Float> {
        val s = innerDrawScale(level, w.toDouble(), h.toDouble()).toFloat()
        val drop = innerSink(level, w.toDouble(), h.toDouble()).drop.toFloat()
        return Pair(w / 2 + (x - w / 2) / s, h / 2 + (y - drop - h / 2) / s)
    }

    /** The zoom level a hop layer asks for; null (your circle) is 0. */
    fun level(hop: Int?): Double =
        if (hop == null) 0.0 else (hop - TrustMapOuter.FIRST_HOP + 1).coerceIn(1, MAX_LEVEL).toDouble()

    fun innerScale(level: Double): Double = lerp(INNER_SCALES, level)
    fun innerAlpha(level: Double): Double = lerp(INNER_ALPHAS, level)

    /** A ring's radius on screen. [outline] is the inner globe's outline radius unzoomed; [half] half the frame's short side. */
    fun radius(hop: Int, level: Double, outline: Double, half: Double): Double =
        blend(level) { radius(hop, it, outline, half) }

    /** The inner globe's outline on screen at [level]: where hop 3's links land. */
    fun innerOutline(level: Double, outline: Double): Double = outline * innerScale(level)

    /** How strongly [hop]'s ring is drawn: all at 0, then the picked full, inside ones back, past ones gone. */
    fun visibility(hop: Int, level: Double): Double = blend(level) { visibility(hop, it) }

    /** How much [hop]'s ring is the picked one: full strength, bigger dots, its lines. */
    fun emphasis(hop: Int, level: Double): Double = blend(level) { emphasis(hop, it) }

    private fun radius(hop: Int, whole: Int, outline: Double, half: Double): Double {
        val outward = (hop - TrustMapOuter.FIRST_HOP).toDouble()
        if (whole == 0) return outline * (FIRST + STEP * outward)
        // Hop 2 (the inner globe) at the shrunk outline, the picked ring at
        // the fit, and the rings between evenly spaced.
        val inner = outline * INNER_SCALES[whole]
        val gap = (FIT * half - inner) / whole
        return inner + gap * (outward + 1)
    }

    private fun visibility(hop: Int, whole: Int): Double {
        if (whole == 0) return 1.0
        val picked = TrustMapOuter.FIRST_HOP + whole - 1
        return when {
            hop == picked -> 1.0
            hop < picked -> INSIDE_ALPHA
            else -> 0.0
        }
    }

    private fun emphasis(hop: Int, whole: Int): Double =
        if (whole > 0 && hop == TrustMapOuter.FIRST_HOP + whole - 1) 1.0 else 0.0

    private inline fun blend(level: Double, at: (Int) -> Double): Double {
        val z = if (level.isFinite()) level.coerceIn(0.0, MAX_LEVEL.toDouble()) else 0.0
        val lo = floor(z).toInt()
        val hi = minOf(MAX_LEVEL, lo + 1)
        val a = at(lo)
        return a + (at(hi) - a) * (z - lo)
    }

    private fun lerp(table: DoubleArray, level: Double): Double = blend(level) { table[it] }
}
