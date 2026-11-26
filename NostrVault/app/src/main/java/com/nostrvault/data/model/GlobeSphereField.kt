package com.nostrvault.data.model

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Where a picked hop's people sit in its sphere (Logen 2026-11-25: "a 360 3d
 * globe view of that ring", not a flat ring at the edge). Picking Hop 3, 4 or
 * 5 turns that ring into a globe of its own, round your nested inner one. Its
 * people sit out on the sphere's skin the way the Hop 2 shell's do ("fill the
 * globe on the outer edge just like the vouched group"), so its faces cover
 * the whole side facing you out to the rim. The top are on the skin; the haze
 * sits in a shallow band just under it, so the rim reads as a ball of dust,
 * not one thin line. Each one's direction comes from a 2D low-discrepancy
 * sequence that does not follow rank, so any run of the best (the faces) is
 * spread all the way round, never in one cap.
 *
 * Points come out inside the unit ball in the globe's own space, so the same
 * camera turn that spins the inner globe spins this one (one drag turns
 * both). Worked out once per ring and pole; each frame only turns them.
 * iOS `Models/GlobeSphereField.swift`.
 */
object GlobeSphereField {
    /** Each point's turn round the pole is nudged by up to this, radians, from its key. */
    const val TWIST = 0.35

    /** The haze sits from this far out (of the sphere's radius) to the skin, by its key. */
    const val HAZE_DEPTH = 0.8

    /** How far away the sphere is seen from, in radii: the near side is a little bigger than the far. */
    const val EYE = 3.4

    /**
     * The point of the globe that faces you at rest: [GlobeCamera.facing]
     * turns the core's direction to the front, so the sphere's pole is the
     * globe-space point that same turn brings to dead centre.
     */
    fun pole(center: String): Vec3 {
        val rest = GlobeCamera.facing(TrustMap.direction(center))
        // The inverse turn (a unit quaternion's conjugate) of the screen's middle.
        val m = Quat(rest.w, -rest.x, -rest.y, -rest.z).matrix()
        return Vec3(m[2], m[5], m[8]).normalized()
    }

    /**
     * Points for [keys], best first, as x0, y0, z0, x1, … : the first [top] on
     * the unit sphere's skin, the rest (the haze) in the band from
     * [HAZE_DEPTH] to the skin.
     */
    fun points(keys: List<String>, top: Int, pole: Vec3): DoubleArray {
        val p = pole.normalized()
        // Any axis not along the pole gives the two directions across it.
        val helper = if (abs(p.y) < 0.9) Vec3(0.0, 1.0, 0.0) else Vec3(1.0, 0.0, 0.0)
        val u = helper.cross(p).normalized()
        val v = p.cross(u)
        // R2 sequence (plastic number): even over the sphere for any run of i.
        val g = 1.32471795724474602596
        val a1 = 1 / g
        val a2 = 1 / (g * g)
        val out = DoubleArray(keys.size * 3)
        keys.forEachIndexed { i, key ->
            val x = i.toDouble()
            val c = 1 - 2 * ((0.5 + x * a1) % 1.0)
            val s = sqrt(maxOf(0.0, 1 - c * c))
            val wobble = GlobeHazeField.hash(key).second
            val a = 2 * Math.PI * ((0.5 + x * a2) % 1.0) + TWIST * (2 * wobble - 1)
            val rho = if (i < top) 1.0 else HAZE_DEPTH + (1 - HAZE_DEPTH) * wobble
            val ca = cos(a)
            val sa = sin(a)
            out[3 * i] = (p.x * c + u.x * s * ca + v.x * s * sa) * rho
            out[3 * i + 1] = (p.y * c + u.y * s * ca + v.y * s * sa) * rho
            out[3 * i + 2] = (p.z * c + u.z * s * ca + v.z * s * sa) * rho
        }
        return out
    }

    /**
     * How far toward you a point's direction faces (0 back, 1 front), whatever
     * its depth: a face shows on the near half of its own shell, so faces come
     * in all round the ball, not only on its front skin.
     */
    fun facing(x: Double, y: Double, z: Double): Double {
        val l = sqrt(x * x + y * y + z * z)
        return if (l > 0) (z / l + 1) / 2 else 0.5
    }

    /**
     * Which of a sphere's top (best first) keep their pictures loaded, by
     * index, from each one's 0-1 [fronts]: the best [faces] that can show a
     * face now (front at least [faceFrom]), and the best [coming] just round
     * the rim (from [comingFrom]), so a face is ready as the sphere turns it
     * in. Never the whole top.
     */
    fun window(fronts: DoubleArray, faceFrom: Double, comingFrom: Double, faces: Int, coming: Int): List<Int> {
        val shown = fronts.indices.filter { fronts[it] >= faceFrom }.take(faces)
        val rim = fronts.indices.filter { fronts[it] >= comingFrom && fronts[it] < faceFrom }.take(coming)
        return shown + rim
    }

    /** A turned point on screen against the sphere's outline: x, y within -1..1 of its centre (y down), its scale, and front 0 (back) to 1. */
    data class Projected(val x: Double, val y: Double, val scale: Double, val front: Double)

    fun project(x: Double, y: Double, z: Double): Projected {
        val s = EYE / (EYE - z)
        // The outline of a unit sphere EYE away, so the edge lands on 1.
        val fit = sqrt(EYE * EYE - 1) / EYE
        return Projected(x * s * fit, -y * s * fit, s, (z + 1) / 2)
    }
}
