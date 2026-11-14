package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Android reads and writes kind 15 DM files exactly as the web (#2075) and the D0 vectors
 * (docs/DM_FILE_VECTORS.json, byte-identical copies in every app's tests).
 */
class DMFileVectorsTest {
    private val doc = Json.parseToJsonElement(
        javaClass.classLoader!!.getResource("dm-file/DM_FILE_VECTORS.json")!!.readText(),
    ).jsonObject
    private val vectors = doc["vectors"]!!.jsonArray.map { it.jsonObject }

    private fun JsonObject.s(k: String) = this[k]!!.jsonPrimitive.content
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun tags(o: JsonObject) = o["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }

    @Test
    fun `every vector reads as it expects`() {
        assertEquals(10, vectors.size)
        for (v in vectors) {
            val id = v.s("id")
            val expect = v.s("expect")
            // What the rumor says is what a received message is kept as.
            val kept = DMFile.contentOf(v["rumor"]!!.jsonObject)
            if (expect == "reject_algorithm" || expect == "reject_key") {
                assertFalse(id, DMFile.isFileLink(kept))
                continue
            }
            val link = DMFile.parseFileLink(kept)
            assertNotNull(id, link)
            assertEquals(id, v["rumor"]!!.jsonObject.s("content"), link!!.url)
            assertEquals(id, v.s("key"), link.key)
            assertEquals(id, v.s("nonce"), link.nonce)
            assertEquals(id, v.s("x"), link.x)
            assertEquals(id, v.s("ox"), link.ox)
            assertEquals(id, v.s("file_type"), link.mime)
            val cipher = hex(v.s("ciphertext_hex"))
            if (expect == "ok") {
                assertArrayEquals(id, hex(v.s("plaintext_hex")), DMFile.decrypt(cipher, link.key, link.nonce, link.x, link.ox))
            } else {
                try {
                    DMFile.decrypt(cipher, link.key, link.nonce, link.x, link.ox)
                    fail("$id should be refused ($expect)")
                } catch (_: DMFile.Refused) {
                }
            }
        }
    }

    @Test
    fun `encrypting with a vector's key and nonce gives its ciphertext and tags`() {
        for (v in vectors.filter { it.s("expect") == "ok" }) {
            val id = v.s("id")
            val enc = DMFile.encrypt(hex(v.s("plaintext_hex")), hex(v.s("key")), hex(v.s("nonce")))
            assertArrayEquals(id, hex(v.s("ciphertext_hex")), enc.cipher)
            assertEquals(id, v.s("x"), enc.x)
            assertEquals(id, v.s("ox"), enc.ox)
            assertEquals(id, v["size"]!!.jsonPrimitive.int, enc.cipher.size)
            val rumor = v["rumor"]!!.jsonObject
            val msg = DMFile.fileMessage(rumor.s("content"), enc, v.s("file_type"))
            assertEquals(id, rumor.s("content"), msg.content)
            // The rumor's tags after its p tag, in the same order.
            assertEquals(id, tags(rumor).drop(1), msg.tags)
            assertEquals(id, msg.shown, DMFile.contentOf(rumor))
        }
    }

    @Test
    fun `a fresh encryption opens and uses a new key and nonce each time`() {
        val plain = "hello".toByteArray()
        val a = DMFile.encrypt(plain)
        val b = DMFile.encrypt(plain)
        assertEquals(64, a.key.length)
        assertEquals(24, a.nonce.length)
        assertTrue(a.key != b.key && a.nonce != b.nonce)
        assertArrayEquals(plain, DMFile.decrypt(a.cipher, a.key, a.nonce, a.x, a.ox))
    }

    @Test
    fun `the kept link is the web's link`() {
        // web dm-file.js fileLink("https://files.example/f", {key, nonce, x, mime}) (no o: the web leaves ox out)
        val k = "1".repeat(64); val n = "2".repeat(24); val x = "3".repeat(64)
        val web = "https://files.example/f#nv-dm=" + java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString("""{"k":"$k","n":"$n","x":"$x","m":"image/png"}""".toByteArray())
        assertEquals(web, DMFile.fileLink("https://files.example/f", k, n, x, "image/png"))
        val parsed = DMFile.parseFileLink(web)!!
        assertNull(parsed.ox)
        assertEquals("image/png", parsed.mime)
    }

    @Test
    fun `a kind 15 with no https file is not a message, an unencrypted one is its bare link`() {
        fun rumor(content: String, tags: String = "[]") =
            Json.parseToJsonElement("""{"kind":15,"content":"$content","tags":$tags}""").jsonObject
        assertNull(DMFile.contentOf(rumor("not a url")))
        assertNull(DMFile.contentOf(rumor("http://plain.example/a.png")))
        assertEquals("https://plain.example/a.png", DMFile.contentOf(rumor("https://plain.example/a.png")))
        assertEquals("Photo", DMFile.previewOf(DMFile.fileLink("https://a.example/f", "1".repeat(64), "2".repeat(24), null, null)))
        assertNull(DMFile.previewOf("https://plain.example/a.png"))
    }
}
