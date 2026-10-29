package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * DECK-0003 §1.9, checked against the spec's own table: the worked example of
 * Appendix A, one rejection per numbered rule (decks/sno-reference.py
 * `_rejections`), and the two real objects the plan was written against.
 */
class SnoObjectTest {
    private val appendixA = """
        {"v":2,"name":"tetra","unit":0,"mode":"solid",
         "vertices":[[0,0,0],[2,0,0],[1,0,2],[1,2,1]],
         "colors":[238,235,239,225],
         "faces":[[0,1,2],[0,3,1],[1,3,2],[0,2,3]]}
    """.trimIndent()

    /** Appendix A with [over] (raw JSON values) put over its fields. */
    private fun variant(vararg over: Pair<String, String>): String {
        val base = Json.parseToJsonElement(appendixA).jsonObject.toMutableMap()
        for ((k, v) in over) base[k] = Json.parseToJsonElement(v)
        return JsonObject(base).toString()
    }

    private fun ok(content: String): SnoObject = when (val r = SnoObject.read(content)) {
        is SnoObject.Read.Ok -> r.obj
        is SnoObject.Read.Rejected -> { fail("rejected: ${r.reason}"); throw AssertionError() }
    }

    private fun rejected(content: String): String = when (val r = SnoObject.read(content)) {
        is SnoObject.Read.Ok -> { fail("accepted: $content"); "" }
        is SnoObject.Read.Rejected -> r.reason
    }

    private fun resource(name: String) =
        javaClass.classLoader!!.getResource("sno/$name")!!.readText()

    @Test fun theWorkedExampleReads() {
        val t = ok(appendixA)
        assertEquals("tetra", t.name)
        assertEquals(SnoObject.Mode.SOLID, t.mode)
        assertEquals(4, t.vertexCount)
        assertEquals(4, t.faceCount)
        // 238 red, 235 green, 239 blue, 225 white in the built-in.
        assertArrayEquals(intArrayOf(0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF), t.vertexColors)
        assertNull(t.faceColors)
    }

    @Test fun everyRuleRejectsWhatTheReferenceRejects() {
        val e64 = "cd".repeat(32)
        val cases = listOf(
            "rule 1" to variant("v" to "3"),
            "rule 1" to variant("v" to "0"),
            "rule 1" to variant("v" to "true"),
            "rule 2" to variant("colors" to "[238]"),
            "rule 4" to variant("mode" to "\"wireframe\""),
            "rule 5" to variant("unit" to "85"),
            "rule 5" to variant("unit" to "1.5"),
            "rule 6" to variant("vertices" to "[[0,0,0],[2,0,0],[1,0,2],[1,2,1.5]]"),
            "rule 7" to variant("ticks" to "[-3]"),
            "rule 7" to variant("ticks" to "[[0,0,120],-3]"),
            "rule 7" to variant("ticks" to "[4]"),
            "rule 8" to variant("faces" to "[[0,1,9]]"),
            "rule 8" to variant("faces" to "[[0,1,1]]"),
            "rule 8a" to variant("palette" to "[[255,0,0]]"),
            "rule 8a" to variant("palette" to "[[255,0,0,0],[0,0,0]]"),
            "rule 8a" to variant("palette" to "\"rainbow\""),
            "rule 8b" to variant("colors" to "[0,1,2,256]"),
            "rule 8b" to variant("colors" to "[0,1,2,-1]"),
            "rule 8b" to variant("colors" to "[0,1,2,1.5]"),
            "rule 8c" to variant("facecolors" to "[238]"),
            "rule 8c" to variant("facecolors" to "[238,-4]"),
            "rule 8c" to variant("facecolors" to "[-4]"),
            "rule 8c" to variant("facecolors" to "[238,256,-2]"),
            "rule 10" to variant("up" to "\"yes\""),
            "rule 10" to variant("up" to "true", "spin" to "360"),
            "rule 10" to variant("spin" to "360"),
            "rule 11" to variant("refs" to "\"x\""),
            "rule 11" to variant("refs" to "[[\"a\",\"33331:${"AB".repeat(32)}:d\"]]"),
            "rule 11" to variant("refs" to "[[\"a\",\"30023:${"ab".repeat(32)}:d\"]]"),
            "rule 11" to variant("refs" to "[[\"e\",\"${"cd".repeat(31)}\"]]"),
            "rule 11" to variant("refs" to "[[\"p\",\"${"ab".repeat(32)}\"]]"),
            "rule 11" to variant("refs" to "[[\"e\",\"$e64\",\"wss://x\",\"extra\"]]"),
            "rule 12" to variant("parts" to "[[0,0,0,0,0,0,0,0]]"),
            "rule 12" to variant("refs" to "[[\"e\",\"$e64\"]]", "parts" to "[[1,0,0,0,0,0,0,0]]"),
            "rule 12" to variant("refs" to "[[\"e\",\"$e64\"]]", "parts" to "[[0,7681,0,0,0,0,0,0]]"),
            "rule 12" to variant("refs" to "[[\"e\",\"$e64\"]]", "parts" to "[[0,0,0,0,360,0,0,0]]"),
            "rule 12" to variant("refs" to "[[\"e\",\"$e64\"]]", "parts" to "[[0,0,0,0,0,0,0]]"),
        )
        for ((rule, content) in cases) {
            val reason = rejected(content)
            assertTrue("$rule expected, got: $reason", reason.startsWith("$rule:"))
        }
        assertTrue(rejected("not json").isNotBlank())
        assertTrue(rejected("[1,2,3]").startsWith("rule 1:"))
    }

    @Test fun legacyTypeExtentOpacityAndConstrainNeverReject() {
        ok(variant("type" to "\"shard\""))
        ok(variant("type" to "17"))
        ok(variant("extent" to "500"))
        ok(variant("opacity" to "null"))
        ok(variant("constrain" to "\"sideways\""))
        ok(variant("up" to "false"))
    }

    @Test fun ticksAddTheirRemainder() {
        val t = ok(variant("ticks" to "[-3,[60,0,30]]"))
        // vertex 3 is [1,2,1] + [60,0,30]/120
        assertEquals(1.5f, t.positions[9], 1e-6f)
        assertEquals(2f, t.positions[10], 1e-6f)
        assertEquals(1.25f, t.positions[11], 1e-6f)
    }

    @Test fun versionOneNegatesZAndTakesLiteralColours() {
        val v1 = variant(
            "v" to "1",
            "colors" to "[[1,0,0],[0,1,0],[0,0,1],[1.5,-1,0.5]]",
        )
        val a = ok(appendixA)
        val b = ok(v1)
        for (i in 0 until 4) {
            assertEquals(a.positions[i * 3], b.positions[i * 3], 0f)
            assertEquals(-a.positions[i * 3 + 2], b.positions[i * 3 + 2], 0f)
        }
        assertEquals(0xFF0000, b.vertexColors[0])
        // Clamped on read: 1.5 → 255, -1 → 0, 0.5 → 127.
        assertEquals((255 shl 16) or 127, b.vertexColors[3])
        assertTrue(rejected(variant("v" to "1")).startsWith("rule 8b:"))
    }

    @Test fun faceColoursRunAndPalettesCanBeInlineOrReferences() {
        val t = ok(variant("facecolors" to "[238,-3]"))
        assertArrayEquals(IntArray(4) { 0xFF0000 }, t.faceColors)
        val four = ok(variant("palette" to "[[1,2,3],[4,5,6],[7,8,9],[10,11,12]]", "colors" to "[0,1,2,3]"))
        assertEquals((10 shl 16) or (11 shl 8) or 12, four.vertexColors[3])
        // An unresolved reference is the built-in, never a rejection (§1.3b).
        ok(variant("palette" to "\"nevent1qqsrq87elpx42dwvq3rjwndwpc6539udtau0vvzvh2ezpwv4pxjz5cq\""))
        ok(variant("palette" to "\"cyberspace-neon-256\""))
    }

    @Test fun anObjectMayBeOnlyItsParts() {
        val e64 = "cd".repeat(32)
        val t = ok(variant(
            "vertices" to "[]", "colors" to "[]", "faces" to "[]",
            "refs" to "[[\"e\",\"$e64\"],[\"a\",\"33331:${"ab".repeat(32)}:door\",\"wss://relay\"]]",
            "parts" to "[[0,240,0,-120,90,0,0,0],[1,0,0,0,0,0,0,1]]",
        ))
        assertEquals(0, t.vertexCount)
        assertEquals(2f, t.partOrigins[0], 0f)
        assertEquals(-1f, t.partOrigins[2], 0f)
    }

    @Test fun theNameIsCutAt64() {
        assertEquals(64, ok(variant("name" to "\"${"x".repeat(100)}\"")).name.length)
    }

    @Test fun theTwoRealObjectsRead() {
        val aj = ok(resource("aj_fu.json"))
        assertEquals("AJ FU", aj.name)
        assertEquals(SnoObject.Mode.LINES, aj.mode)
        assertEquals(40, aj.vertexCount)
        assertEquals(69, aj.faceCount)
        val key = ok(resource("silver_key.json"))
        assertEquals("Silver Key", key.name)
        assertEquals(SnoObject.Mode.SOLID, key.mode)
        assertEquals(32, key.vertexCount)
        assertEquals(60, key.faceCount)
        // Its first tick is [6, 18, 0]: x is the whole part plus 6/120.
        assertEquals(6 / 120f, key.positions[0] - kotlin.math.floor(key.positions[0]), 1e-5f)
    }

    @Test fun theBuiltInPaletteIsAppendixC() {
        assertEquals(256, SnoPalette.BUILT_IN.size)
        assertEquals(0xFF0000, SnoPalette.BUILT_IN[238])
        assertEquals(0xFFFFFF, SnoPalette.BUILT_IN[225])
        assertEquals(0x003632, SnoPalette.BUILT_IN[0])
    }
}
