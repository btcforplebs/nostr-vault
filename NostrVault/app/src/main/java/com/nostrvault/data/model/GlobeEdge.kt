package com.nostrvault.data.model

/**
 * How live stars and faces fade at the globe's edge instead of popping (iOS
 * `GlobeEdge.swift`). Everything is a smooth function of depth (toward the
 * viewer: about −1.6 at the back, 1.6 at the front), so a turning globe never steps.
 */
object GlobeEdge {
    /** A face is whole above this depth... */
    const val FACE_FULL = 0.25
    /** ...and gone below this one. */
    const val FACE_GONE = -0.1

    /** Smooth 0 → 1 between [a] and [b], flat outside them. */
    fun smoothstep(a: Double, b: Double, x: Double): Double {
        val t = ((x - a) / (b - a)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /** How much of a face shows at [depth]: 1 at the front, 0 round the back. */
    fun face(depth: Double) = smoothstep(FACE_GONE, FACE_FULL, depth)

    /** A face's radius as it fades: it shrinks to three fifths, not to a point. */
    fun faceRadius(r: Double, shown: Double) = r * (0.6 + 0.4 * shown)

    /** Brightness of a live star, line or light at [depth]: full in front, a third round the back, smooth between. */
    fun arc(depth: Double) = 0.35 + 0.65 * smoothstep(-0.45, 0.05, depth)
}
