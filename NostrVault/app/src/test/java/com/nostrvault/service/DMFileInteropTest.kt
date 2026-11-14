package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail
import org.junit.Test

/**
 * Android matches the web (#2075) byte-for-byte on the shared interop fixture
 * (DM_FILE_INTEROP.json from PR #2076, made by the web's own gif-strip.js + dm-file.js).
 */
class DMFileInteropTest {
    private val doc = Json.parseToJsonElement(
        javaClass.classLoader!!.getResource("dm-file/DM_FILE_INTEROP.json")!!.readText(),
    ).jsonObject

    private fun JsonObject.s(k: String) = this[k]!!.jsonPrimitive.content
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun `GIFs strip to the web's bytes and the web's refusals are refused`() {
        val pairs = doc["gif_strip"]!!.jsonArray.map { it.jsonObject }
        assertEquals(3, pairs.size)
        for (p in pairs) {
            assertArrayEquals(p.s("id"), hex(p.s("output_hex")), GifStrip.strip(hex(p.s("input_hex"))))
        }
        val refused = doc["gif_refused_hex"]!!.jsonObject
        assertEquals(3, refused.size)
        for ((id, v) in refused) {
            try { GifStrip.strip(hex(v.jsonPrimitive.content)); fail("$id should be refused") } catch (_: GifStrip.NotAGif) {}
        }
    }

    @Test
    fun `a kind 15 sent with the web's key and nonce is the web's ciphertext and rumor`() {
        val k = doc["kind15_send"]!!.jsonObject
        val enc = DMFile.encrypt(hex(k.s("plaintext_hex")), hex(k.s("key")), hex(k.s("nonce")))
        assertArrayEquals(hex(k.s("ciphertext_hex")), enc.cipher)
        assertEquals(k.s("x"), enc.x)
        assertEquals(k.s("ox"), enc.ox)
        assertEquals(k.s("url"), "https://nostr.download/" + enc.x)
        val msg = DMFile.fileMessage(k.s("url"), enc, k.s("mime"))
        assertEquals(15, k["rumor_kind"]!!.jsonPrimitive.content.toInt())
        assertEquals(k.s("rumor_content"), msg.content)
        val webTags = k["rumor_file_tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals(webTags, msg.tags)
        assertArrayEquals(hex(k.s("plaintext_hex")), DMFile.decrypt(enc.cipher, enc.key, enc.nonce, enc.x, enc.ox))
    }

    @Test
    fun `the web's kept link reads as the web parsed it and opens the ciphertext`() {
        val k = doc["kind15_send"]!!.jsonObject
        val parsed = k["web_parsed"]!!.jsonObject
        val link = DMFile.parseFileLink(k.s("web_local_link"))
        assertNotNull(link)
        assertEquals(parsed.s("url"), link!!.url)
        assertEquals(parsed.s("key"), link.key)
        assertEquals(parsed.s("nonce"), link.nonce)
        assertEquals(parsed.s("x"), link.x)
        assertEquals(parsed.s("mime"), link.mime)
        assertArrayEquals(hex(k.s("plaintext_hex")), DMFile.decrypt(hex(k.s("ciphertext_hex")), link.key, link.nonce, link.x, link.ox))
    }
}
