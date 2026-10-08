package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.min

/** Port of iOS TrustMapTests. */
class TrustMapTest {

    private val me = "0".repeat(64)
    private val author = "a".repeat(64)

    private fun key(n: Int) = String.format("%064x", n.toLong() * 0x1234567 + 1)

    private fun list(signer: String, tags: List<String>, at: Long = 0) =
        ContactList(signer, at, tags.map { listOf("p", it) })

    /** Keys spread over all their hex digits, like real ones. */
    private fun randomKey(n: Int): String {
        var h = 0x9E3779B97F4A7C15uL * (n + 1).toULong()
        return (0 until 4).joinToString("") {
            h = (h xor (h shr 31)) * 0xBF58476D1CE4E5B9uL
            String.format("%016x", h.toLong())
        }
    }

    @Test fun `direction comes from the key and stays put`() {
        // Longitude is the leading digits; height is the next eight.
        val front = TrustMap.direction("00000000" + "80000000" + "f".repeat(48))
        assertEquals(1.0, front.x, 1e-9)
        assertEquals(0.0, front.z, 1e-9)
        val pole = TrustMap.direction("40000000" + "ffffffff" + "f".repeat(48))
        assertEquals(1.0, pole.z, 1e-8)
        for (n in 0 until 200) {
            val d = TrustMap.direction(randomKey(n))
            assertEquals(1.0, d.length, 1e-9)
            assertEquals(d, TrustMap.direction(randomKey(n)))
        }
        // Not hex: still stable and on the sphere.
        assertEquals(TrustMap.direction("not-a-key"), TrustMap.direction("not-a-key"))
        assertEquals(1.0, TrustMap.direction("not-a-key").length, 1e-9)
    }

    @Test fun `directions cover the whole sphere`() {
        // Even spread: each hemisphere, both ways, holds about half.
        val dirs = (0 until 4000).map { TrustMap.direction(randomKey(it)) }
        for ((axis, up) in listOf(dirs.count { it.x > 0 }, dirs.count { it.y > 0 }, dirs.count { it.z > 0 }).withIndex()) {
            assertTrue("axis $axis: $up of 4000", up in 1800..2200)
        }
    }

    @Test fun `haze is capped, stable and keeps its people as the set grows`() {
        val small = (0 until 10).map(::randomKey).toSet()
        assertEquals(small.sorted(), TrustMap.haze(small, cap = 20))
        val all = (0 until 6000).map(::randomKey).toSet()
        val picked = TrustMap.haze(all, cap = 2500)
        assertEquals(2500, picked.size)
        assertEquals(picked, TrustMap.haze(all.shuffled().toSet(), cap = 2500))
        // Adding people only swaps out those at the margin: the shell doesn't reshuffle.
        val more = all + (6000 until 6600).map(::randomKey)
        val kept = picked.toSet().intersect(TrustMap.haze(more, cap = 2500).toSet())
        assertTrue("kept ${kept.size}", kept.size > 2100)
    }

    // ── Globe camera ─────────────────────────────────────────────────

    private fun flicked() = GlobeCamera().apply { flick(800.0, -300.0, 0.0, reduceMotion = false) }

    private fun run(camera: GlobeCamera, hz: Double, seconds: Double, reduceMotion: Boolean = false) {
        val dt = 1 / hz
        var now = 0.0
        repeat((seconds * hz).toInt()) {
            now += dt
            camera.step(dt, now, reduceMotion)
        }
    }

    private fun assertSameTurn(expected: Quat, actual: Quat) {
        assertEquals(1.0, abs(expected.dot(actual)), 1e-9)
    }

    @Test fun `spin feels the same at 60 and 120 Hz`() {
        val at60 = flicked(); val at120 = flicked()
        run(at60, hz = 60.0, seconds = 1.5)
        run(at120, hz = 120.0, seconds = 1.5)
        assertEquals(at60.spin.length, at120.spin.length, 1e-6)
        // Same orientation to within a fraction of a degree.
        val apart = 2 * acos(min(1.0, abs(at60.orientation.dot(at120.orientation))))
        assertTrue("apart $apart", apart < 0.01)
    }

    @Test fun `flick glides then settles`() {
        val camera = flicked()
        run(camera, hz = 120.0, seconds = 8.0)
        assertTrue(camera.spin.isZero)
    }

    @Test fun `fly to arrives and lets the clock sleep`() {
        val camera = GlobeCamera().apply { zoom = 2.0; zoomTarget = 2.0 }
        val target = GlobeCamera.facing(TrustMap.direction(randomKey(7)))
        camera.fly(target, 0.0)
        // Arrives (and zooms back out) before the idle drift starts at 3 s.
        run(camera, hz = 120.0, seconds = 2.5)
        assertNull(camera.flyTarget)
        assertEquals(target, camera.orientation)
        assertEquals(1.0, camera.zoom, 0.0)
        // Still awake for the idle drift, asleep once idle long enough.
        assertTrue(camera.wantsFrames(2.5, reduceMotion = false))
        assertFalse(camera.wantsFrames(GlobeCamera.SLEEP_AFTER + 1, reduceMotion = false))
    }

    @Test fun `facing brings the direction to the front`() {
        val d = TrustMap.direction(randomKey(11))
        val m = GlobeCamera.facing(d).matrix()
        val turned = Vec3(m[0] * d.x + m[1] * d.y + m[2] * d.z, m[3] * d.x + m[4] * d.y + m[5] * d.z,
            m[6] * d.x + m[7] * d.y + m[8] * d.z)
        val want = Vec3(0.42, 0.30, 1.0).normalized()
        assertEquals(want.x, turned.x, 1e-9)
        assertEquals(want.y, turned.y, 1e-9)
        assertEquals(want.z, turned.z, 1e-9)
    }

    @Test fun `idle drift stops before the clock sleeps`() {
        val camera = GlobeCamera()
        var now = 0.0
        while (now < GlobeCamera.SLEEP_AFTER) { now += 1 / 120.0; camera.step(1 / 120.0, now, reduceMotion = false) }
        val before = camera.orientation
        camera.step(1 / 120.0, now + 1 / 120.0, reduceMotion = false)
        assertEquals(before, camera.orientation)
    }

    @Test fun `reduce motion cuts instead of gliding`() {
        val camera = GlobeCamera()
        camera.flick(800.0, 0.0, 0.0, reduceMotion = true)
        assertTrue(camera.spin.isZero)
        val target = GlobeCamera.facing(TrustMap.direction(randomKey(3)))
        camera.fly(target, 0.0)
        camera.step(1 / 120.0, 1 / 120.0, reduceMotion = true)
        assertNull(camera.flyTarget)
        assertEquals(target, camera.orientation)
        // No idle drift, and nothing keeps the clock awake once still.
        val still = camera.orientation
        camera.step(1 / 120.0, 5.0, reduceMotion = true)
        assertEquals(still, camera.orientation)
        assertFalse(camera.wantsFrames(5.0, reduceMotion = true))
    }

    @Test fun `a hitch cannot fling the globe`() {
        val smooth = flicked(); val hitched = flicked()
        smooth.step(GlobeCamera.MAX_STEP, 1.0, reduceMotion = false)
        hitched.step(2.0, 1.0, reduceMotion = false)
        assertEquals(smooth.orientation, hitched.orientation)
    }

    @Test fun `slerp takes the short way and lands on both ends`() {
        val a = Quat.angle(0.3, Vec3(0.0, 1.0, 0.0))
        val b = Quat.angle(2.0, Vec3(1.0, 0.0, 0.0))
        assertSameTurn(a, Quat.slerp(a, b, 0.0))
        assertSameTurn(b, Quat.slerp(a, b, 1.0))
        // The same turn written with the opposite sign blends the same way.
        val negB = Quat(-b.w, -b.x, -b.y, -b.z)
        assertSameTurn(Quat.slerp(a, b, 0.4), Quat.slerp(a, negB, 0.4))
    }

    // ── Data ─────────────────────────────────────────────────────────

    @Test fun `spread picks evenly through the list`() {
        val keys = (0 until 48).map(::key)
        assertEquals(listOf(keys[0], keys[12], keys[24], keys[36]), TrustMap.spread(keys, 4))
        assertEquals(keys.take(3), TrustMap.spread(keys.take(3), 12))
        assertEquals(keys, TrustMap.spread(keys, 0))
    }

    @Test fun `next batch skips seen and the author`() {
        val filters = TrustMap.nextBatch(author, listOf(key(1), key(2), author, key(3)), setOf(key(2)))
        assertEquals(1, filters.size)
        assertEquals(listOf(key(1), key(3)), filters[0].authors)
        assertEquals(listOf(author), filters[0].tagged)
        assertEquals(TrustMap.BATCH_SIZE, filters[0].limit)
        assertTrue(TrustMap.nextBatch(author, listOf(key(1), author), setOf(key(1))).isEmpty())
        // Someone with thousands of follows is asked about in chunks.
        val many = (1..2500).map(::key)
        assertEquals(listOf(1000, 1000, 500), TrustMap.nextBatch(author, many, emptySet(), 1000).map { it.authors!!.size })
    }

    @Test fun `follows of uses only the owner's newest list`() {
        val owner = key(7)
        val lists = listOf(
            list(owner, listOf(key(1)), at = 100),
            list(owner, listOf(key(2), key(2), owner, "short"), at = 200),
            list(key(8), listOf(key(9)), at = 300),
        )
        assertEquals(listOf(key(2)), TrustMap.follows(owner, lists))
        assertNull(TrustMap.follows(key(5), lists))
    }

    @Test fun `all bridges is uncapped`() {
        val follows = (1..9).map(::key).toSet()
        val lists = follows.map { list(it, listOf(author)) }
        val all = TrustPath.allBridges(author, me, follows, lists)
        assertEquals(follows.sorted(), all)
        assertEquals(all.take(5), TrustPath.resolve(author, me, follows, setOf("x"), lists).bridges)
    }

    @Test fun `deeper chains`() {
        val bridge = key(1); val other = key(2); val via = key(3); val stranger = key(4)
        val follows = setOf(bridge, other)
        // A follow's list is not a middle step (that's 2 hops), and neither is your own.
        val seeds = listOf(list(via, listOf(author)), list(stranger, listOf(author)),
            list(bridge, listOf(author)), list(me, listOf(author)))
        val viaList = TrustMap.deeperVia(author, me, follows, setOf(stranger), seeds)
        assertEquals("people in your graph come first", listOf(stranger, via), viaList)

        val filters = TrustMap.deeperLinkFilters(follows.sorted(), viaList)
        assertEquals(1, filters.size)
        assertEquals(viaList, filters[0].tagged)

        // A stranger's list can't invent a route; only your follows' lists count.
        val links = listOf(list(bridge, listOf(via, key(9))), list(other, listOf(stranger, via)), list(key(5), listOf(via)))
        assertEquals(
            listOf(TrustMap.Chain(other, stranger), TrustMap.Chain(bridge, via), TrustMap.Chain(other, via))
                .sortedWith(compareBy({ it.via }, { it.bridge })),
            TrustMap.chains(me, follows, viaList, links),
        )
        assertTrue(TrustMap.deeperLinkFilters(listOf(bridge), emptyList()).isEmpty())
    }
}
