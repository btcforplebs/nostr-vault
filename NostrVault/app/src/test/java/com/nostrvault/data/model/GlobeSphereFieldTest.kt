package com.nostrvault.data.model

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * A picked hop as its own sphere (Logen 2026-11-25): where its people sit,
 * and when a ring is drawn as a sphere rather than flat.
 * iOS `GlobeSphereFieldTests.swift`.
 */
class GlobeSphereFieldTest {
    private fun pk(i: Int) = "%064x".format(i)

    /** Varied bytes all the way along, like a real key, so each has its own wobble. */
    private fun hex(i: Int) = (0 until 8).joinToString("") { "%08x".format(((i + 1) * 2_654_435_761L + it * 40_503L) and 0xffffffffL) }

    private fun len(p: DoubleArray, i: Int) = sqrt(p[3 * i] * p[3 * i] + p[3 * i + 1] * p[3 * i + 1] + p[3 * i + 2] * p[3 * i + 2])

    @Test fun `the top sit on the skin and the haze just under it`() {
        val keys = (0 until 2000).map(::hex)
        val pole = GlobeSphereField.pole(pk(0xa))
        val p = GlobeSphereField.points(keys, 300, pole)
        assertEquals(6000, p.size)
        for (i in 0 until 300) assertEquals("faces out on the edge", 1.0, len(p, i), 1e-9)
        val haze = (300 until 2000).map { len(p, it) }
        assertTrue("clear of the nested globe", haze.all { it >= GlobeSphereField.HAZE_DEPTH - 1e-9 && it <= 1 + 1e-9 })
        assertTrue("a band, not one thin limb ring", haze.max() - haze.min() > 0.15)
        assertArrayEquals("it never moves", p, GlobeSphereField.points(keys, 300, pole), 0.0)
    }

    @Test fun `the best spread all round`() {
        val keys = (0 until 1000).map(::pk)
        val p = GlobeSphereField.points(keys, 300, GlobeSphereField.pole(pk(0xa)))
        val octants = HashSet<Int>()
        var mx = 0.0; var my = 0.0; var mz = 0.0
        for (i in 0 until 40) {
            val l = len(p, i)
            val x = p[3 * i] / l; val y = p[3 * i + 1] / l; val z = p[3 * i + 2] / l
            octants += (if (x > 0) 1 else 0) or (if (y > 0) 2 else 0) or (if (z > 0) 4 else 0)
            mx += x / 40; my += y / 40; mz += z / 40
        }
        assertEquals("faces all round", 8, octants.size)
        assertTrue("no cap", sqrt(mx * mx + my * my + mz * mz) < 0.15)
        val front = (0 until 300).filter { p[3 * it + 2] > 0 }.map { GlobeSphereField.project(p[3 * it], p[3 * it + 1], p[3 * it + 2]) }
        val outer = front.count { sqrt(it.x * it.x + it.y * it.y) > 0.7 }
        assertTrue("front faces out to the edge", outer.toDouble() / front.size > 0.35)
    }

    @Test fun `the same keys land where iOS puts them`() {
        // R2 index 0 sits at c = 0 (the equator round the pole), whatever the key.
        val pole = Vec3(0.0, 0.0, 1.0)
        val p = GlobeSphereField.points(listOf(pk(1)), 1, pole)
        assertEquals(0.0, p[2], 1e-12)
        assertEquals(1.0, len(p, 0), 1e-12)
    }

    @Test fun `facing is the direction not the depth`() {
        assertEquals(1.0, GlobeSphereField.facing(0.0, 0.0, 0.4), 1e-12)
        assertEquals(0.0, GlobeSphereField.facing(0.0, 0.0, -0.4), 1e-12)
        assertEquals(0.5, GlobeSphereField.facing(0.4, 0.0, 0.0), 1e-12)
    }

    @Test fun `the outline lands on the sphere edge`() {
        val e = GlobeSphereField.EYE
        val z = 1 / e
        val side = sqrt(1 - z * z)
        assertEquals(1.0, GlobeSphereField.project(side, 0.0, z).x, 1e-9)
        assertEquals(1.0, GlobeSphereField.project(0.0, 0.0, 1.0).front, 0.0)
        assertEquals(0.0, GlobeSphereField.project(0.0, 0.0, -1.0).front, 0.0)
        assertTrue("near side bigger", GlobeSphereField.project(0.0, 0.0, 1.0).scale > GlobeSphereField.project(0.0, 0.0, -1.0).scale)
    }

    @Test fun `the pole is what the rest turn brings to the middle`() {
        val center = pk(0xa)
        val m = GlobeCamera.facing(TrustMap.direction(center)).matrix()
        val p = GlobeSphereField.pole(center)
        // Turned by the rest orientation, the pole faces you dead on.
        val z = m[6] * p.x + m[7] * p.y + m[8] * p.z
        assertEquals(1.0, z, 1e-9)
    }

    @Test fun `a ring is a sphere once picked and stays one while nested`() {
        assertEquals("your circle draws every ring flat", 0.0, GlobeRingZoom.sphere(3, 0.0), 0.0)
        assertEquals(1.0, GlobeRingZoom.sphere(3, 1.0), 0.0)
        assertEquals(0.0, GlobeRingZoom.sphere(4, 1.0), 0.0)
        assertEquals("ring 3 nests under Hop 4, still a sphere", 1.0, GlobeRingZoom.sphere(3, 2.0), 0.0)
        assertEquals(1.0, GlobeRingZoom.sphere(4, 2.0), 0.0)
        assertEquals("no flat flash between Hop 3 and Hop 4", 1.0, GlobeRingZoom.sphere(3, 1.5), 0.0)
        assertEquals("grows out of the flat ring", 0.5, GlobeRingZoom.sphere(3, 0.5), 1e-9)
    }

    @Test fun `the window holds only what can be drawn plus what is coming round`() {
        val fronts = DoubleArray(300) { 1 - it / 299.0 }
        val w = GlobeSphereField.window(fronts, 0.45, 0.3, 72, 36)
        assertEquals("not every one on the front", 72 + 36, w.size)
        assertEquals("the best that can show a face", (0 until 72).toList(), w.take(72))
        assertTrue("the rest are at the rim", w.drop(72).all { fronts[it] >= 0.3 && fronts[it] < 0.45 })
        assertEquals("no one twice", w.size, w.toSet().size)
        assertEquals("nothing round the back", emptyList<Int>(), GlobeSphereField.window(doubleArrayOf(0.1, 0.2), 0.45, 0.3, 72, 36))
        assertTrue(abs(fronts[0] - 1) < 1e-12)
    }
}
