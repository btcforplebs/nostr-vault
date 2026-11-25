package com.nostrvault.data.model

import kotlin.math.floor
import kotlin.math.min

/**
 * The WOT tab's Hop 3, Hop 4 and Hop 5 layers zoom your own globe out to
 * that outer ring: the inner globe shrinks and fades in place, nested in the
 * middle, and the picked ring grows into a sphere of its own round it that
 * fills the frame (Logen 2026-11-24, "best visual effort"; a sphere, not a
 * flat ring, 2026-11-25).
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
    /** Rings past the picked one, round its sphere, this strongly. */
    const val PAST_ALPHA = 0.8

    /**
     * How much [hop]'s ring is drawn as its own sphere (0 to 1) rather than a
     * flat ring: once it is picked, and still while it is nested inside a
     * later pick. Your circle (level 0) draws every ring flat.
     */
    fun sphere(hop: Int, level: Double): Double = min(1.0, emphasis(hop, level) + inside(hop, level))

    // ── Nest (Logen 2026-11-25) ──

    /**
     * Everything inside the picked ring (the inner globe, and the rings between
     * it and the picked one) stays centred and shrinks in place inside the
     * picked ring's sphere ([com.nostrvault.ui.components.GlobeHopSphere]),
     * nested like the layers of an onion (not dropping down below). How much
     * smaller it is drawn at each whole level, on top of [INNER_SCALES].
     */
    val NEST_SCALES = doubleArrayOf(1.0, 0.8, 0.74, 0.68)

    /** How much [hop]'s ring is nested inside the picked one (0 to 1): the inner globe (hop 2 and in) once any hop is picked, an outer ring once a hop past it is. */
    fun inside(hop: Int, level: Double): Double = blend(level) { if (it > 0 && hop < TrustMapOuter.FIRST_HOP + it - 1) 1.0 else 0.0 }

    /** How much smaller [hop]'s ring is drawn at [level], round the frame's middle: 1 unless it is nested inside the picked one. */
    fun nest(hop: Int, level: Double): Double = 1 - inside(hop, level) * (1 - lerp(NEST_SCALES, level))

    /** The inner globe's whole drawn scale at [level], round the frame's middle: [innerScale] times its nest. */
    fun innerDrawScale(level: Double): Double = innerScale(level) * nest(TrustMapOuter.FIRST_HOP - 1, level)

    /** How much past the frame (as a share of its size, each side) the shrunk inner globe still lands on screen: its stars there must be kept. */
    fun cullGrow(level: Double): Double = (1 / innerDrawScale(level) - 1) / 2

    /** A tap at ([x], [y]) on screen, in the inner globe's own unshrunk frame. */
    fun unnest(x: Float, y: Float, w: Float, h: Float, level: Double): Pair<Float, Float> {
        val s = innerDrawScale(level).toFloat()
        return Pair(w / 2 + (x - w / 2) / s, h / 2 + (y - h / 2) / s)
    }

    /** Where a point ([x], [y]) of the unshrunk inner globe is drawn on screen: [unnest]'s inverse. */
    fun nested(x: Double, y: Double, w: Double, h: Double, level: Double): Pair<Double, Double> {
        val s = innerDrawScale(level)
        return Pair(w / 2 + (x - w / 2) * s, h / 2 + (y - h / 2) * s)
    }

    /** The zoom level a hop layer asks for; null (your circle) is 0. */
    fun level(hop: Int?): Double =
        if (hop == null) 0.0 else (hop - TrustMapOuter.FIRST_HOP + 1).coerceIn(1, MAX_LEVEL).toDouble()

    fun innerScale(level: Double): Double = lerp(INNER_SCALES, level)
    fun innerAlpha(level: Double): Double = lerp(INNER_ALPHAS, level)

    /**
     * A ring's radius on screen. [outline] is the inner globe's outline radius
     * unzoomed; [half] half the frame's short side; [grow] how far a pinch has
     * zoomed in, so the picked sphere grows with the globe nested in it.
     */
    fun radius(hop: Int, level: Double, outline: Double, half: Double, grow: Double = 1.0): Double =
        blend(level) { radius(hop, it, outline, half, grow) }

    /** The inner globe's outline on screen at [level]: where hop 3's links land. */
    fun innerOutline(level: Double, outline: Double): Double = outline * innerScale(level)

    /** How strongly [hop]'s ring is drawn: all at 0, then the picked full, inside ones back, past ones round it. */
    fun visibility(hop: Int, level: Double): Double = blend(level) { visibility(hop, it) }

    /** How much [hop]'s ring is the picked one: full strength, its faces and taps. */
    fun emphasis(hop: Int, level: Double): Double = blend(level) { emphasis(hop, it) }

    private fun radius(hop: Int, whole: Int, outline: Double, half: Double, grow: Double): Double {
        val outward = (hop - TrustMapOuter.FIRST_HOP).toDouble()
        if (whole == 0) return outline * (FIRST + STEP * outward)
        // Hop 2 (the inner globe) at the shrunk outline, the picked ring at
        // the fit, and the rings between evenly spaced.
        val inner = outline * INNER_SCALES[whole]
        val fitted = FIT * half * grow
        // Rings past the picked one stay round its sphere, spaced as at your
        // circle (STEP against FIRST), the way Hop 3 and 4 sit round your
        // globe on Vouched (Logen 2026-11-25).
        val past = (hop - (TrustMapOuter.FIRST_HOP + whole - 1)).toDouble()
        if (past > 0) return fitted * (1 + STEP / FIRST * past)
        val gap = (fitted - inner) / whole
        return inner + gap * (outward + 1)
    }

    private fun visibility(hop: Int, whole: Int): Double {
        if (whole == 0) return 1.0
        val picked = TrustMapOuter.FIRST_HOP + whole - 1
        return when {
            hop == picked -> 1.0
            hop < picked -> INSIDE_ALPHA
            else -> PAST_ALPHA
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
