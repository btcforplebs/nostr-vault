package com.nostrvault.ui.components

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Constellation.kt against the web's vectors (RESEARCH/NV_CONSTELLATION_AVATAR_SPEC.md); all three apps load this file. */
class ConstellationVectorsTest {
    private val file = File("../../web-vault/test/fixtures/CONSTELLATION_VECTORS.json")
    private val vectors: List<JsonObject> by lazy {
        assertTrue("vectors not found at ${file.absolutePath}", file.isFile)
        Json.parseToJsonElement(file.readText()).jsonObject["vectors"]!!.jsonArray.map { it.jsonObject }
    }

    private fun hex(rgb: Int) = "#%06x".format(rgb)
    private fun nums(a: JsonArray) = a.map { it.jsonArray.map { n -> n.jsonPrimitive.double } }

    @Test fun allFiveVectors() {
        assertEquals(5, vectors.size)
        for (v in vectors) {
            val pk = v["hex"]!!.jsonPrimitive.content
            val c = Constellation.of(pk)
            val seed = Constellation.fnv1a(Constellation.hexBytes(pk))
            assertEquals(pk, v["seed"]!!.jsonPrimitive.content, "0x%08x".format(seed))
            val rnd = Constellation.mulberry32(seed)
            v["firstDraws"]!!.jsonArray.forEach { assertEquals(pk, it.jsonPrimitive.double, rnd(), 1e-9) }
            assertEquals(pk, v["hue"]!!.jsonPrimitive.int, c.hue)
            assertEquals(pk, v["n"]!!.jsonPrimitive.int, c.stars.size)
            assertEquals(pk, nums(v["stars"]!!.jsonArray), c.stars.map { listOf(it.x, it.y, it.r) })
            assertEquals(pk, v["links"]!!.jsonArray.map { l -> l.jsonArray.map { it.jsonPrimitive.int } }, c.links.map { listOf(it.first, it.second) })
            assertEquals(pk, v["you"]!!.jsonPrimitive.int, c.you)
            assertEquals(pk, nums(v["dust"]!!.jsonArray), c.dust.map { listOf(it.x, it.y, it.r) })
            val clouds = v["clouds"]!!.jsonArray.map { k -> k.jsonArray.map { it.jsonPrimitive.content } }
            assertEquals(pk, clouds, c.clouds.map { listOf(fmt(it.x), fmt(it.y), fmt(it.radius), hex(it.color), fmt(it.alpha)) })
            assertEquals(pk, v["sky"]!!.jsonArray.map { it.jsonPrimitive.content }, listOf(hex(c.skyInner), hex(c.skyOuter)))
            assertEquals(pk, v["line"]!!.jsonPrimitive.content, hex(c.line))
            assertEquals(pk, v["star"]!!.jsonPrimitive.content, hex(c.star))
            assertEquals(pk, v["glow"]!!.jsonPrimitive.content, hex(c.glow))
        }
    }

    /** JSON number text as JS writes it (42, 0.5, 22.35). */
    private fun fmt(d: Double): String = if (d == Math.floor(d)) d.toLong().toString() else d.toString()

    @Test fun sameAnswerTwice() {
        val pk = vectors[0]["hex"]!!.jsonPrimitive.content
        assertEquals(Constellation.of(pk), Constellation.of(pk))
    }

    @Test fun onlyFullHexPubkeysDraw() {
        assertTrue(Constellation.isPubkey(vectors[0]["hex"]!!.jsonPrimitive.content))
        assertEquals(false, Constellation.isPubkey("npub1xyz"))
        assertEquals(false, Constellation.isPubkey(""))
    }
}
