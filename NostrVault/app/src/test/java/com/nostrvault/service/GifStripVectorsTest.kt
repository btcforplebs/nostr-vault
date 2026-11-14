package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** Android strips a DM GIF to the same bytes as the web (docs/DM_GIF_STRIP_VECTORS.json, made by gif-strip.js). */
class GifStripVectorsTest {
    private val vectors = Json.parseToJsonElement(
        javaClass.classLoader!!.getResource("dm-file/DM_GIF_STRIP_VECTORS.json")!!.readText(),
    ).jsonObject["vectors"]!!.jsonArray.map { it.jsonObject }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun `every vector strips to the web's bytes or is refused`() {
        assertEquals(6, vectors.size)
        for (v in vectors) {
            val id = v["id"]!!.jsonPrimitive.content
            val input = hex(v["input_hex"]!!.jsonPrimitive.content)
            if (v["expect"]!!.jsonPrimitive.content == "ok") {
                assertArrayEquals(id, hex(v["output_hex"]!!.jsonPrimitive.content), GifStrip.strip(input))
            } else {
                try { GifStrip.strip(input); fail("$id should be refused") } catch (_: GifStrip.NotAGif) {}
            }
        }
    }

    @Test
    fun `a big one-frame GIF strips without copying its frame bytes`() {
        val header = "GIF89a".toByteArray() + byteArrayOf(1, 0, 1, 0, 0, 0, 0)
        val image = byteArrayOf(0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2)
        val blocks = java.io.ByteArrayOutputStream()
        repeat(40 * 1024 * 1024 / 255) { blocks.write(255); blocks.write(ByteArray(255)) }
        blocks.write(0)
        val gif = header + image + blocks.toByteArray() + byteArrayOf(0x3b)
        assertEquals(gif.size, GifStrip.strip(gif).size)
    }
}
