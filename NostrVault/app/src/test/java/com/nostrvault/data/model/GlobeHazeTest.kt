package com.nostrvault.data.model

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * The zoomed-out rings' haze (Logen 2026-11-24): decoding `haze`, the rings
 * it lands in, where its dots sit, and the inner globe's sink.
 * iOS twin: `MediaLogicTests/GlobeHazeTests.swift`.
 */
class GlobeHazeTest {
    private fun pk(i: Int) = "%064x".format(i)
    private val me = pk(0xa)

    /** globe: ring 3 top 1, 2; ring 4 top 3 (via 1). haze as given. */
    private fun copy(haze: String?): TrustRankCopy? {
        val globe = "[\"${pk(1)}\",80,3,\"${pk(9)}\"],[\"${pk(2)}\",70,3,\"${pk(9)}\"],[\"${pk(3)}\",20,4,\"${pk(1)}\"]"
        val field = haze?.let { ",\"haze\":$it" } ?: ""
        val text = "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6," +
            "\"people\":[[\"${pk(9)}\",100,1]],\"globe\":[$globe],\"viewBar\":55,\"floor\":45$field}"
        return TrustRankCopy.parse(text, me)
    }

    private fun rows(from: Int, n: Int, score: Int = 10) =
        (0 until n).joinToString(",", "[", "]") { "[\"${pk(from + it)}\",$score]" }

    @Test fun `haze decodes best first per ring`() {
        val c = copy("{\"3\":${rows(100, 3)},\"4\":${rows(200, 2)}}")!!
        assertEquals(listOf(pk(100), pk(101), pk(102)), c.haze[3])
        assertEquals(listOf(pk(200), pk(201)), c.haze[4])
        assertNull("haze rows are not globe rows", c.globeRow(pk(100)))
        assertEquals("an engine from before H1", emptyMap<Int, List<String>>(), copy(null)!!.haze)
    }

    @Test fun `a bad haze costs only the haze`() {
        val cap = TrustRankCopy.HAZE_PER_RING.getValue(3)
        for (haze in listOf(
            "{\"5\":${rows(100, 1)}}", // no hop-5 haze
            "{\"2\":${rows(100, 1)}}",
            "{\"03\":${rows(100, 1)}}",
            "{\"3\":${rows(100, 1, score = 0)}}",
            "{\"3\":${rows(100, 1, score = 101)}}",
            "{\"3\":[[\"nope\",10]]}",
            "{\"3\":[[\"${pk(100)}\",\"10\"]]}", // score as text
            "{\"3\":[[\"${pk(1)}\",10]]}", // already a globe row
            "{\"3\":${rows(100, 1)},\"4\":${rows(100, 1)}}", // in two rings
            "{\"3\":${rows(100, cap + 1)}}",
            "[1,2]",
        )) {
            val c = copy(haze)
            assertNotNull(haze, c)
            assertEquals(haze, emptyMap<Int, List<String>>(), c!!.haze)
            assertEquals("the globe stays: $haze", 3, c.globe.size)
            assertEquals(1, c.people.size)
        }
        val past = kotlinx.serialization.json.Json.parseToJsonElement("{\"4\":[[\"${pk(100)}\",10]]}")
        assertEquals("past maxHop", emptyMap<Int, List<String>>(), TrustRankCopy.parseHaze(past, 3, emptyList()))
        assertEquals(mapOf(4 to listOf(pk(100))), TrustRankCopy.parseHaze(past, 4, emptyList()))
        assertEquals("a full ring is kept", 700, copy("{\"3\":${rows(100, cap)}}")!!.haze[3]!!.size)
    }

    @Test fun `the caps are the contract's`() {
        val contract = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "docs/MESH_COPY_V2_CONTRACT.md") }.first { it.exists() }.readText()
        val m = Regex("""at most ([0-9,]+) and ([0-9,]+) rows""").find(contract.replace(Regex("\\s+"), " "))!!
        assertEquals(m.groupValues[1].replace(",", "").toInt(), TrustRankCopy.HAZE_PER_RING[3])
        assertEquals(m.groupValues[2].replace(",", "").toInt(), TrustRankCopy.HAZE_PER_RING[4])
        assertEquals("no hop-5 haze", listOf(3, 4), TrustRankCopy.HAZE_PER_RING.keys.sorted())
    }

    @Test fun `rings carry their haze less blocked people`() {
        val c = copy("{\"3\":${rows(100, 3)},\"4\":${rows(200, 2)}}")!!
        val outer = TrustMapOuter.make(c, desktopPaired = true, hidden = setOf(pk(101)))
        assertEquals(listOf(pk(100), pk(102)), outer.rings.first { it.hop == 3 }.haze)
        assertEquals(listOf(pk(200), pk(201)), outer.rings.first { it.hop == 4 }.haze)
        assertEquals("the chip counts the tappable top only", 2, outer.rings.first { it.hop == 3 }.count)
    }

    @Test fun `the best sit nearest the centre and every dot is in the field`() {
        val keys = (0 until 2000).map(::pk)
        val p = GlobeHazeField.positions(keys)
        val d = (keys.indices).map { hypot(p[2 * it].toDouble(), p[2 * it + 1].toDouble()) }
        val j = GlobeHazeField.JITTER
        for (r in d) assertTrue(r >= GlobeHazeField.NEAREST - j - 1e-6 && r <= GlobeHazeField.FURTHEST + j + 1e-6)
        assertTrue("best nearest the centre", d.take(200).average() < d.takeLast(200).average())
        // A dot's angle is its key's, the same as the ring's dots.
        val a = atan2(p[15].toDouble(), p[14].toDouble())
        val want = GlobeHazeField.hash(keys[7]).first
        assertEquals(cos(want), cos(a), 1e-6)
        assertEquals(sin(want), sin(a), 1e-6)
        assertArrayEquals("it never moves", p, GlobeHazeField.positions(keys), 0f)
    }

    @Test fun `the hash matches iOS's unsigned fold, and the ring dots keep their old angle`() {
        // Old GlobeOuterRings.angle: signed Long, floorMod. Hex keys never overflow 8 chars.
        val key = "ffffffff" + "0".repeat(56)
        var head = 0L
        for (c in key.take(8)) head = head * 31 + c.code
        assertEquals(Math.floorMod(head, 3600L) / 3600.0 * 2 * Math.PI, GlobeHazeField.hash(key).first, 0.0)
        // UTF-8 bytes of "0123456789abcdef": next = fold("89abcdef").
        val next = "89abcdef".fold(0uL) { acc, c -> acc * 31uL + c.code.toULong() }
        assertEquals((next % 1000uL).toDouble() / 1000, GlobeHazeField.hash("0123456789abcdef").second, 0.0)
    }

    @Test fun `rings inside the picked one sink and the picked ring stays centred`() {
        val half = 200.0
        assertEquals(0.0, GlobeRingZoom.sink(2, 0.0, half).drop, 0.0)
        assertEquals(1.0, GlobeRingZoom.sink(2, 0.0, half).scale, 0.0)
        for (hop in 3..5) {
            val level = GlobeRingZoom.level(hop)
            val picked = GlobeRingZoom.sink(hop, level, half)
            assertEquals("the picked ring stays centred", 0.0, picked.drop, 0.0)
            assertEquals(1.0, picked.scale, 0.0)
            for (inner in 2 until hop) {
                val s = GlobeRingZoom.sink(inner, level, half)
                assertTrue("hop $inner sinks down at Hop $hop", s.drop > 0.3 * half)
                assertTrue(s.scale < 0.85)
                // A sunk ring stays inside the picked one.
                val r = if (inner < 3) GlobeRingZoom.innerOutline(level, 0.5 * half)
                    else GlobeRingZoom.radius(inner, level, 0.5 * half, half)
                assertTrue("hop $inner at Hop $hop", s.drop + r * s.scale < GlobeRingZoom.FIT * half)
            }
        }
        // It eases: no jump between picks, both ways.
        var last = GlobeRingZoom.sink(2, 0.0, half).drop
        for (step in 1..300) {
            val d = GlobeRingZoom.sink(2, step / 100.0, half).drop
            assertTrue(abs(d - last) < 0.02 * half)
            last = d
        }
    }

    @Test fun `a tap on the sunk globe maps back to the globe's own frame`() {
        val (w, h) = 400f to 800f
        assertEquals(200f to 400f, GlobeRingZoom.unsink(200f, 400f, w, h, 0.0))
        assertEquals(0.0, GlobeRingZoom.cullGrow(0.0, 400.0, 800.0), 0.0)
        val s = GlobeRingZoom.innerDrawScale(1.0, 400.0, 800.0)
        assertEquals(GlobeRingZoom.innerScale(1.0) * GlobeRingZoom.SINK_SCALES[1], s, 1e-9)
        val drop = GlobeRingZoom.innerSink(1.0, 400.0, 800.0).drop
        // The globe's middle is drawn at (200, 400 + drop); a point 30 px right of it there is 30 / s right of the middle.
        val (x, y) = GlobeRingZoom.unsink(230f, (400 + drop).toFloat(), w, h, 1.0)
        assertEquals(200 + 30 / s, x.toDouble(), 1e-3)
        assertEquals(400.0, y.toDouble(), 1e-3)
    }
}
