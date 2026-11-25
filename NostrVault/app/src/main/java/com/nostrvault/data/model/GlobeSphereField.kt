package com.nostrvault.data.model

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Where a picked hop's people sit on its sphere (Logen 2026-11-25: "a 360 3d
 * globe view of that ring", not a flat ring at the edge). Picking Hop 3 or
 * Hop 4 turns that ring into a globe of its own, round your nested inner one;
 * its people are spread over the whole surface, best first from the pole that
 * faces you when the globe is at rest, so the best scores sit nearest the
 * front and centre and the haze wraps round the back.
 *
 * Points come out on the unit sphere in the globe's own space, so the same
 * camera turn that spins the inner globe spins this one (one drag turns
 * both). A Fibonacci spiral out from the pole spreads them evenly; a small
 * twist from each key keeps the spiral from reading as a pattern. Worked out
 * once per ring and pole; each frame only turns them. Pure math, so the tests
 * pin it. iOS `Models/GlobeSphereField.swift`.
 */
object GlobeSphereField {
    /** Each point's turn round the pole is nudged by up to this, radians, from its key. */
    const val TWIST = 0.35

    /** Seen from this many radii away, so the near side is a little bigger than the far side. */
    const val EYE = 3.4

    /**
     * The point of the globe that faces you at rest: [GlobeCamera.facing] turns
     * the core's direction to the front, so the sphere's pole is the
     * globe-space point that same turn brings to dead centre (the rest turn's
     * third row, as [com.nostrvault.ui.components.GlobeScene.Projector.facing]).
     */
    fun pole(center: String): Vec3 {
        val m = GlobeCamera.facing(TrustMap.direction(center)).matrix()
        return Vec3(m[6], m[7], m[8]).normalized()
    }

    /** Unit-sphere points for [keys], best first, as x0, y0, z0, x1, …: the first at the pole, the last at the far side. */
    fun points(keys: List<String>, pole: Vec3): DoubleArray {
        val p = pole.normalized()
        // Any axis not along the pole gives the two directions across it.
        val helper = if (abs(p.y) < 0.9) Vec3(0.0, 1.0, 0.0) else Vec3(1.0, 0.0, 0.0)
        val u = helper.cross(p).normalized()
        val v = p.cross(u)
        val n = maxOf(keys.size, 1).toDouble()
        val golden = Math.PI * (3 - sqrt(5.0))
        val out = DoubleArray(keys.size * 3)
        keys.forEachIndexed { i, key ->
            // Equal area per point: the cosine of the angle from the pole falls evenly from 1 to -1.
            val c = 1 - 2 * (i + 0.5) / n
            val s = sqrt(maxOf(0.0, 1 - c * c))
            val a = i * golden + TWIST * (2 * GlobeHazeField.hash(key).second - 1)
            val sc = s * cos(a)
            val ss = s * sin(a)
            out[3 * i] = p.x * c + u.x * sc + v.x * ss
            out[3 * i + 1] = p.y * c + u.y * sc + v.y * ss
            out[3 * i + 2] = p.z * c + u.z * sc + v.z * ss
        }
        return out
    }

    /** The outline of a unit sphere [EYE] away, so the edge lands on 1. */
    private val FIT = sqrt(EYE * EYE - 1) / EYE

    /**
     * How a point the camera turned to ([vx], [vy], [vz]) lands on screen,
     * against the sphere's outline, into [out]: x and y within -1..1 of its
     * centre (y down), its scale, and front from 0 at the back to 1 at the front.
     */
    fun project(vx: Double, vy: Double, vz: Double, out: DoubleArray) {
        val s = EYE / (EYE - vz)
        out[0] = vx * s * FIT
        out[1] = -vy * s * FIT
        out[2] = s
        out[3] = (vz + 1) / 2
    }
}
