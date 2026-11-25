package com.nostrvault.data.model

/**
 * A key's fixed angle round a flat outer ring
 * ([com.nostrvault.ui.components.GlobeOuterRings.angle]) and a 0-1 wobble,
 * both from the key alone, so a dot never moves. The picked hop's sphere
 * ([GlobeSphereField]) uses the wobble to break up its spiral.
 * Pure math, so the tests can pin it. iOS `Models/GlobeHazeField.swift`.
 */
object GlobeHazeField {
    /**
     * The angle from the key's first 8 characters, and a 0-1 wobble from its
     * next 8. Unsigned 64-bit folds, so it matches iOS for any key.
     */
    fun hash(key: String): Pair<Double, Double> {
        fun fold(part: String): ULong = part.fold(0uL) { acc, c -> acc * 31uL + c.code.toULong() }
        val head = fold(key.take(8))
        val next = fold(key.drop(8).take(8))
        return Pair((head % 3600uL).toDouble() / 3600 * 2 * Math.PI, (next % 1000uL).toDouble() / 1000)
    }
}
