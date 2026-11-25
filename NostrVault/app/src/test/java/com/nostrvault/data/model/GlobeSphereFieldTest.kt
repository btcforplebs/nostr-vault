package com.nostrvault.data.model

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sqrt

/** A picked hop's own sphere (Logen 2026-11-25). iOS twin: `MediaLogicTests/GlobeSphereFieldTests.swift`. */
class GlobeSphereFieldTest {
    private fun pk(i: Int) = "%064x".format(i)
    private val keys = (0 until 1000).map(::pk)

    @Test fun `points stay on the unit sphere and never move`() {
        val pole = GlobeSphereField.pole(pk(0xa))
        val p = GlobeSphereField.points(keys, pole)
        for (i in keys.indices) {
            val l = sqrt(p[3 * i] * p[3 * i] + p[3 * i + 1] * p[3 * i + 1] + p[3 * i + 2] * p[3 * i + 2])
            assertEquals(1.0, l, 1e-9)
        }
        assertArrayEquals(p, GlobeSphereField.points(keys, pole), 0.0)
    }

    @Test fun `the best sit front and centre at rest, the last round the back`() {
        val center = pk(0xa)
        val pole = GlobeSphereField.pole(center)
        val m = GlobeCamera.facing(TrustMap.direction(center)).matrix()
        val p = GlobeSphereField.points(keys, pole)
        fun z(i: Int) = m[6] * p[3 * i] + m[7] * p[3 * i + 1] + m[8] * p[3 * i + 2]
        // At rest the pole faces you: the camera turns it to dead centre.
        assertEquals(1.0, m[6] * pole.x + m[7] * pole.y + m[8] * pole.z, 1e-9)
        assertTrue("the best faces you", z(0) > 0.99)
        assertTrue("the last is round the back", z(keys.size - 1) < -0.99)
        assertTrue((0 until 100).map(::z).average() > (900 until 1000).map(::z).average())
        // Even: about half face you.
        val front = keys.indices.count { z(it) > 0 }
        assertTrue(abs(front - 500) < 20)
    }

    @Test fun `the outline lands on the edge and the near side is bigger`() {
        val out = DoubleArray(4)
        // A point on the rim as seen from EYE radii away: tangent from the eye.
        val e = GlobeSphereField.EYE
        val z = 1 / e
        GlobeSphereField.project(sqrt(1 - z * z), 0.0, z, out)
        assertEquals(1.0, out[0], 1e-9)
        GlobeSphereField.project(0.0, 0.0, 1.0, out)
        val near = out[2]
        assertEquals(1.0, out[3], 0.0)
        GlobeSphereField.project(0.0, 0.0, -1.0, out)
        assertTrue(near > out[2])
        assertEquals(0.0, out[3], 0.0)
        // y runs down the screen.
        GlobeSphereField.project(0.0, 0.5, 0.0, out)
        assertTrue(out[1] < 0)
    }
}
