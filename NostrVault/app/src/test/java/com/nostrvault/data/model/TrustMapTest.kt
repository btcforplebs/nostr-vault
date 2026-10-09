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

    @Test fun `lite globe is for phones with 4 GB or less`() {
        val gb = 1024L * 1024 * 1024
        assertTrue(TrustMap.isLite(3_725_528L * 1024, lowRamDevice = false)) // moto g play 2026
        assertTrue(TrustMap.isLite(4 * gb, lowRamDevice = false))
        assertFalse(TrustMap.isLite(5_500_000_000L, lowRamDevice = false))
        assertTrue(TrustMap.isLite(8 * gb, lowRamDevice = true))
        // Unknown memory reads as a full phone.
        assertFalse(TrustMap.isLite(0, lowRamDevice = false))
        assertTrue(TrustMap.HAZE_CAP_LITE < TrustMap.HAZE_CAP)
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

    // ── Ring faces ───────────────────────────────────────────────────

    @Test fun `face candidates are the ring sorted and spread`() {
        val ring = (0 until 200).map { randomKey(it) }
        val picked = TrustMap.faceCandidates(ring)
        assertEquals(TrustMap.FACE_CANDIDATES, picked.size)
        assertEquals(TrustMap.spread(ring.sorted(), TrustMap.FACE_CANDIDATES), picked)
        // Order in doesn't matter: the same people every time.
        assertEquals(picked, TrustMap.faceCandidates(ring.reversed()))
        val few = listOf("c", "a", "b")
        assertEquals(listOf("a", "b", "c"), TrustMap.faceCandidates(few))
    }

    @Test fun `face candidates put the most engaged first`() {
        val ring = (0 until 200).map { key(it) }
        val engagement = mapOf(key(150) to 9, key(7) to 4, key(42) to 4, key(999) to 50)
        val picked = TrustMap.faceCandidates(ring, engagement, count = 10)
        // Busiest first, ties by key; someone you don't follow never appears.
        assertEquals(listOf(key(150), key(7), key(42)), picked.take(3))
        assertEquals(10, picked.toSet().size)
        assertTrue(key(999) !in picked)
    }

    @Test fun `pick faces shows only rendered pictures in candidate order`() {
        val candidates = listOf("a", "b", "c", "d", "e")
        val rendered = setOf("b", "d", "e")
        assertEquals(listOf("b", "d"), TrustMap.pickFaces(candidates, { it in rendered }, count = 2))
        assertEquals(listOf("b", "d", "e"), TrustMap.pickFaces(candidates, { it in rendered }))
        assertTrue(TrustMap.pickFaces(candidates, { false }).isEmpty())
        assertTrue(TrustMap.pickFaces(candidates, { true }, count = 0).isEmpty())
        assertEquals(TrustMap.RING_FACES, TrustMap.pickFaces((0 until 100).map { "k$it" }, { true }).size)
    }

    @Test fun `engagement scores count both directions`() {
        val me = key(1); val alice = key(2); val bob = key(3); val carol = key(4)
        fun ev(pubkey: String, kind: Int, vararg tags: List<String>) = TrustMap.Interaction(pubkey, kind, tags.toList())
        val mine = listOf(
            ev(me, 7, listOf("e", "x"), listOf("p", alice)),          // a like: alice +2
            ev(me, 1, listOf("p", bob), listOf("p", alice)),          // reply to alice in bob's thread: alice +2
            ev(me, 6, listOf("p", me)),                               // reposting yourself counts for no one
            ev(bob, 7, listOf("p", carol)),                           // not yours: ignored
        )
        val toMe = listOf(
            ev(bob, 7, listOf("p", me)),                              // bob liked you: +1
            ev("zapper", 9735, listOf("p", me), listOf("P", carol)), // carol zapped you: +3
            ev(carol, 1, listOf("p", alice)),                         // not aimed at you: ignored
        )
        assertEquals(mapOf(alice to 4, bob to 1, carol to 3), TrustMap.engagementScores(mine, toMe, me))
    }

    // ── Search ───────────────────────────────────────────────────────

    private fun person(key: String, display: String? = null, name: String? = null, nip05: String? = null) =
        FeedProfile(pubkey = key, name = name, displayName = display, nip05 = nip05)

    @Test fun `search matches display name, name and nip05 ignoring case`() {
        val people = listOf(
            person("1", display = "Alice Smith"),
            person("2", name = "bob"),
            person("3", nip05 = "carol@ALICE.com"),
            person("4", display = "Dave"),
        )
        val hits = TrustMap.searchPeople("ALICE", people, emptySet(), emptySet()).map { it.pubkey }
        assertEquals(setOf("1", "3"), hits.toSet())
        assertEquals(listOf("2"), TrustMap.searchPeople("Bo", people, emptySet(), emptySet()).map { it.pubkey })
        assertTrue(TrustMap.searchPeople("   ", people, emptySet(), emptySet()).isEmpty())
        assertTrue(TrustMap.searchPeople("zed", people, emptySet(), emptySet()).isEmpty())
    }

    @Test fun `search ranks follows, then web, then prefix, then shorter name`() {
        val people = listOf(
            person("other", display = "Ann"),
            person("web", display = "Ann Web"),
            person("follow", display = "Joanne"),
            person("followPrefixLong", display = "Annabelle"),
            person("followPrefixShort", display = "Anna"),
        )
        val follows = setOf("follow", "followPrefixLong", "followPrefixShort")
        val hits = TrustMap.searchPeople("ann", people, follows, setOf("web"))
        assertEquals(listOf("followPrefixShort", "followPrefixLong", "follow", "web", "other"), hits.map { it.pubkey })
        assertEquals(
            listOf(TrustMap.Tier.FOLLOW, TrustMap.Tier.FOLLOW, TrustMap.Tier.FOLLOW, TrustMap.Tier.WEB, TrustMap.Tier.OTHER),
            hits.map { it.tier },
        )
        // A follow is also in the web: it's still tagged as a follow.
        assertEquals(TrustMap.Tier.FOLLOW, TrustMap.searchPeople("joanne", people, follows, follows).single().tier)
    }

    @Test fun `search stops at the limit`() {
        val people = (0 until 20).map { person("k$it", display = "Sam $it") }
        assertEquals(8, TrustMap.searchPeople("sam", people, emptySet(), emptySet()).size)
        assertEquals(3, TrustMap.searchPeople("sam", people, emptySet(), emptySet(), limit = 3).size)
    }

    @Test fun `a pasted hex key or npub names one person`() {
        val hex = "AB".repeat(32)
        assertEquals(hex.lowercase(), TrustMap.pastedKey("  $hex ") { null })
        assertEquals(author, TrustMap.pastedKey("npub1xyz") { if (it == "npub1xyz") author else null })
        assertEquals(author, TrustMap.pastedKey("nostr:npub1xyz") { author })
        assertNull(TrustMap.pastedKey("npub1bad") { null })
        assertNull(TrustMap.pastedKey("npub1short") { "abc" })
        assertNull(TrustMap.pastedKey("npub1throws") { error("bad checksum") })
        assertNull(TrustMap.pastedKey("alice") { author })
        assertNull(TrustMap.pastedKey("ab".repeat(31)) { null })
    }

    @Test
    fun seatFacesNeverLetsOneFaceCoverAnother() {
        fun spot(k: String, x: Double) = TrustMap.FaceSpot(k, x, 0.0, 10.0)
        // Front-most first: b sits on a, c is clear, d sits on the core.
        val spots = listOf(spot("a", 0.0), spot("b", 5.0), spot("c", 40.0), spot("d", 100.0))
        val core = listOf(TrustMap.FaceSpot("core", 100.0, 0.0, 20.0))
        assertEquals(setOf("a", "c"), TrustMap.seatFaces(spots, blocked = core))
        // A face seated last frame keeps its seat over a newcomer in front.
        assertEquals(setOf("b", "c"), TrustMap.seatFaces(spots, kept = setOf("b"), blocked = core))
        // The author always gets a picture.
        assertEquals(setOf("a", "c", "d"), TrustMap.seatFaces(spots, always = setOf("d"), blocked = core))
        // A little overlap is fine; covering is not.
        assertEquals(setOf("a", "b"), TrustMap.seatFaces(listOf(spot("a", 0.0), spot("b", 18.0))))
        assertEquals(setOf("a"), TrustMap.seatFaces(listOf(spot("a", 0.0), spot("b", 16.0))))
    }

    @Test
    fun layerCountsSplitFollowsFromTheRestAndSkipYou() {
        val follows = setOf(me, key(1), key(2))
        val web = setOf(me, key(1), key(2), key(3), key(4), key(5))
        val counts = TrustMap.layerCounts(me, follows, web)
        assertEquals(2, counts[TrustMap.Layer.FOLLOWING])
        assertEquals(3, counts[TrustMap.Layer.FURTHER_OUT])
        assertEquals(5, counts[TrustMap.Layer.EVERYONE])
        // A follow the relay hasn't mapped yet still counts as a follow.
        assertEquals(1, TrustMap.layerCounts(me, setOf(key(9)), emptySet())[TrustMap.Layer.EVERYONE])
    }

    @Test
    fun pickingALayerDimsTheOtherOneWithoutHidingIt() {
        assertEquals(TrustMap.Weights(1.0, 1.0, 1.0), TrustMap.layerWeights(TrustMap.Layer.EVERYONE))
        for (layer in listOf(TrustMap.Layer.FOLLOWING, TrustMap.Layer.CLOSE, TrustMap.Layer.FURTHER_OUT)) {
            val w = TrustMap.layerWeights(layer)
            // Every part stays faintly there; only the picked one is bright.
            assertTrue("$layer", w.follows > 0 && w.close > 0 && w.further > 0)
        }
        assertEquals(1.0, TrustMap.layerWeights(TrustMap.Layer.FOLLOWING).follows, 0.0)
        assertTrue(TrustMap.layerWeights(TrustMap.Layer.FOLLOWING).close < 0.5)
        assertTrue(TrustMap.layerWeights(TrustMap.Layer.CLOSE).close > 1)
        assertTrue(TrustMap.layerWeights(TrustMap.Layer.CLOSE).further < 0.5)
        assertTrue(TrustMap.layerWeights(TrustMap.Layer.FURTHER_OUT).further > 1)
        assertTrue(TrustMap.layerWeights(TrustMap.Layer.FURTHER_OUT).close < 0.5)
    }

    @Test
    fun closeSplitsTheWebAtTenVouches() {
        val follows = setOf(key(1))
        val web = setOf(me, key(1), key(2), key(3), key(4))
        val vouches = mapOf(key(2) to 10, key(3) to 9, key(4) to 3)
        val counts = TrustMap.layerCounts(me, follows, web, vouches)
        assertEquals(1, counts[TrustMap.Layer.CLOSE])
        assertEquals(2, counts[TrustMap.Layer.FURTHER_OUT])
        assertEquals(4, counts[TrustMap.Layer.EVERYONE])
        // An old cache has no vouches: no Close, and Further out is everyone past your follows.
        val old = TrustMap.layerCounts(me, follows, web)
        assertNull(old[TrustMap.Layer.CLOSE])
        assertEquals(3, old[TrustMap.Layer.FURTHER_OUT])
        assertEquals(listOf(TrustMap.Layer.EVERYONE, TrustMap.Layer.FOLLOWING, TrustMap.Layer.FURTHER_OUT), TrustMap.layers(false))
        assertEquals(TrustMap.Layer.entries, TrustMap.layers(true))
    }

    @Test
    fun vouchesComeFromTheCacheAndAreNullOnAnOldOne() {
        assertEquals(mapOf("a" to 12, "c" to 3),
            TrustMap.vouches("""{"pubkeys":{"a":true},"follows":["b"],"vouches":{"a":12,"c":3}}"""))
        assertNull(TrustMap.vouches("""{"pubkeys":{"a":true},"timestamp":1}"""))
        assertNull(TrustMap.vouches("not json"))
    }
}
