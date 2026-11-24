package com.nostrvault.data.model

import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The haze a zoomed-out Hop 3 or Hop 4 ring shows (Logen 2026-11-24): the
 * ring's people ranked after its top 300 ([TrustRankCopy.haze]), as faint
 * dots that cannot be tapped. Each dot's angle comes from its key, so it
 * never moves; its distance from the ring's centre comes from its rank, the
 * best nearest the centre and the lowest drifting out past the line, with a
 * small jitter from the key. Positions are worked out once per ring in unit
 * space (the ring's radius is 1); each frame only scales them.
 * iOS `Models/GlobeHazeField.swift`.
 */
object GlobeHazeField {
    /** The best haze dot's distance from the centre, against the ring's radius. */
    const val NEAREST = 0.42
    /** The lowest one's. */
    const val FURTHEST = 1.12
    /** Jitter either way, against the ring's radius. */
    const val JITTER = 0.04

    /** Unit-space positions for [keys], best first, as x0, y0, x1, y1, … (ready for drawPoints). */
    fun positions(keys: List<String>): FloatArray {
        val n = maxOf(keys.size, 1).toDouble()
        val out = FloatArray(keys.size * 2)
        keys.forEachIndexed { i, key ->
            val (angle, wobble) = hash(key)
            // sqrt spreads the dots evenly over the area, not bunched in the middle.
            val u = sqrt((i + 0.5) / n)
            val r = NEAREST + (FURTHEST - NEAREST) * u + JITTER * (2 * wobble - 1)
            out[2 * i] = (r * cos(angle)).toFloat()
            out[2 * i + 1] = (r * sin(angle)).toFloat()
        }
        return out
    }

    /**
     * The angle [com.nostrvault.ui.components.GlobeOuterRings.angle] gives the
     * same key, and a 0-1 wobble from the key's next 8 characters. Unsigned
     * 64-bit folds, so it matches iOS for any key.
     */
    fun hash(key: String): Pair<Double, Double> {
        fun fold(part: String): ULong = part.fold(0uL) { acc, c -> acc * 31uL + c.code.toULong() }
        val head = fold(key.take(8))
        val next = fold(key.drop(8).take(8))
        return Pair((head % 3600uL).toDouble() / 3600 * 2 * Math.PI, (next % 1000uL).toDouble() / 1000)
    }
}
