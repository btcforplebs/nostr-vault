package com.nostrvault.shareportal

import com.nostrvault.service.shareportal.handlers.MediaPostShareTags
import com.nostrvault.service.shareportal.handlers.PrivateCopyRecord
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Share Portal lane B against the shared fixtures (media-post-cases.json,
 * private-copy-cases.json), the same cases SharePortalMediaTests.swift runs,
 * so both platforms publish and seal the same bytes.
 */
class SharePortalMediaFixtureTest {
    private val media = ShareFixtures.load("media-post-cases.json")
    private val copy = ShareFixtures.load("private-copy-cases.json")

    private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun tags(e: Any?): List<List<String>> = (e as JsonArray).map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
    private fun hex(s: String): ByteArray = PrivateCopyRecord.unhex(s)!!

    // ── Picture / video post ──

    private fun problemName(p: MediaPostShareTags.Problem) = when (p) {
        MediaPostShareTags.Problem.NOTHING -> "nothing"
        MediaPostShareTags.Problem.MIXED -> "mixed"
        MediaPostShareTags.Problem.TOO_MANY_VIDEOS -> "too_many_videos"
        MediaPostShareTags.Problem.TOO_MANY_PICTURES -> "too_many_pictures"
        MediaPostShareTags.Problem.NOT_MEDIA -> "not_media"
    }

    @Test
    fun `shape fixtures`() {
        val cases = media["shape"]!!.jsonArray
        assertEquals(9, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val mimes = c["mimes"]!!.jsonArray.map { it.jsonPrimitive.content }
            val r = MediaPostShareTags.shape(mimes)
            if (r.shape != null) {
                assertNull(r.problem)
                assertEquals("$mimes", c.s("shape"), if (r.shape == MediaPostShareTags.Shape.PICTURES) "pictures" else "video")
            } else {
                assertEquals("$mimes", c.s("problem"), problemName(r.problem!!))
            }
        }
    }

    @Test
    fun `needs jpeg fixtures`() {
        for (c in media["needs_jpeg"]!!.jsonArray) {
            val pair = c.jsonArray
            assertEquals(pair[0].jsonPrimitive.content, pair[1].jsonPrimitive.boolean, MediaPostShareTags.needsJpeg(pair[0].jsonPrimitive.content))
        }
    }

    @Test
    fun `event fixtures`() {
        val cases = media["events"]!!.jsonArray.map { it.jsonObject }
        assertEquals(4, cases.size)
        for (c in cases) {
            val note = c.s("note")
            val shape = if (c.s("shape") == "video") MediaPostShareTags.Shape.VIDEO else MediaPostShareTags.Shape.PICTURES
            val list = c["media"]!!.jsonArray.map { it.jsonObject }.map { m ->
                MediaPostShareTags.Media(
                    url = m.s("url")!!, mime = m.s("mime")!!, sha256 = m.s("sha256")!!,
                    width = m["width"]?.jsonPrimitive?.int, height = m["height"]?.jsonPrimitive?.int,
                    bytes = m["bytes"]?.jsonPrimitive?.long, duration = m["duration"]?.jsonPrimitive?.double,
                    alt = m.s("alt"),
                )
            }
            val caption = c.s("caption").orEmpty()
            assertEquals(note, c["kind"]!!.jsonPrimitive.int, MediaPostShareTags.kind(shape, list))
            assertEquals(note, c.s("content"), MediaPostShareTags.content(caption))
            val got = MediaPostShareTags.tags(shape, list, c.s("title").orEmpty(), caption, c["published_at"]!!.jsonPrimitive.long)
            assertEquals(note, tags(c["tags"]), got)
        }
    }

    @Test
    fun `duration format`() {
        assertEquals("7", MediaPostShareTags.format(7.0))
        assertEquals("12.5", MediaPostShareTags.format(12.5))
        assertEquals("3.142", MediaPostShareTags.format(3.14159))
        assertEquals("0.05", MediaPostShareTags.format(0.05))
    }

    @Test
    fun `video title from the caption`() {
        assertEquals("Video", MediaPostShareTags.videoTitle(""))
        assertEquals("Second", MediaPostShareTags.videoTitle("\n\n  Second  \nthird"))
        assertEquals("a".repeat(80) + "…", MediaPostShareTags.videoTitle("a".repeat(81)))
    }

    // ── Private copy ──

    @Test
    fun `seal fixtures`() {
        for (c in copy["seal"]!!.jsonArray.map { it.jsonObject }) {
            val sealed = PrivateCopyRecord.seal(hex(c.s("plain_hex")!!), hex(c.s("key")!!), hex(c.s("nonce")!!))
            assertEquals(c.s("note"), c.s("blob_hex"), PrivateCopyRecord.hex(sealed.blob))
            assertEquals(c.s("note"), c.s("x"), sealed.x)
            assertEquals(c.s("note"), c.s("ox"), sealed.ox)
        }
    }

    @Test
    fun `random seal opens and never repeats`() {
        val plain = "a private page".toByteArray()
        val a = PrivateCopyRecord.seal(plain)
        val b = PrivateCopyRecord.seal(plain)
        assertNotEquals(a.key, b.key)
        assertNotEquals(a.nonce, b.nonce)
        assertFalse(a.blob.contentEquals(b.blob))
        assertFalse("the sealed blob must not hold the plain bytes", String(a.blob, Charsets.ISO_8859_1).contains("a private page"))
        val record = PrivateCopyRecord.Record("p.txt", "text/plain", plain.size, a.x, a.ox, a.key, a.nonce, null, null, 1)
        assertArrayEquals(plain, PrivateCopyRecord.open(a.blob, record))
        assertEquals(record, PrivateCopyRecord.decode(PrivateCopyRecord.encode(record)))
    }

    @Test
    fun `record fixtures`() {
        val cases = copy["records"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 10)
        for (c in cases) {
            val decoded = PrivateCopyRecord.decode(c.s("json").orEmpty())
            assertEquals(c.s("note"), c["valid"]!!.jsonPrimitive.boolean, decoded != null)
            if (decoded != null) assertEquals(c.s("note"), decoded, PrivateCopyRecord.decode(PrivateCopyRecord.encode(decoded)))
        }
    }

    @Test
    fun `open fixtures`() {
        val record = assertNotNullAnd(PrivateCopyRecord.decode(copy.s("open_record")!!))
        for (c in copy["open"]!!.jsonArray.map { it.jsonObject }) {
            val blob = hex(c.s("blob_hex")!!)
            if (c["ok"]!!.jsonPrimitive.boolean) {
                assertEquals(c.s("note"), c.s("plain_hex"), PrivateCopyRecord.hex(PrivateCopyRecord.open(blob, record)))
            } else {
                try {
                    PrivateCopyRecord.open(blob, record)
                    fail("${c.s("note")}: opened")
                } catch (_: PrivateCopyRecord.OpenException) {
                }
            }
        }
    }

    @Test
    fun `event ids and tags`() {
        for (c in copy["events"]!!.jsonArray.map { it.jsonObject }) {
            val id = PrivateCopyRecord.id(c["kind"]!!.jsonPrimitive.int, tags(c["tags"]))
            val want = c["id"].takeUnless { it is JsonNull }?.jsonPrimitive?.content
            assertEquals(c.s("note"), want, id)
        }
        val t = copy["tags"]!!.jsonObject
        val id = t.s("id")!!
        assertEquals(tags(t["saved"]), PrivateCopyRecord.tags(id))
        assertEquals(tags(t["cleared"]), PrivateCopyRecord.clearedTags(id))
    }

    @Test
    fun `is ciphertext`() {
        assertFalse(PrivateCopyRecord.isCiphertext("{\"v\":1}"))
        assertFalse(PrivateCopyRecord.isCiphertext(""))
        val ct = java.util.Base64.getEncoder().encodeToString(byteArrayOf(2) + ByteArray(120) { 7 })
        assertTrue(PrivateCopyRecord.isCiphertext(ct))
    }

    @Test
    fun `cleared slots`() {
        assertTrue(PrivateCopyRecord.isCleared("", emptyList()))
        assertTrue(PrivateCopyRecord.isCleared("abc", listOf(listOf("deleted", "true"))))
        assertFalse(PrivateCopyRecord.isCleared("abc", listOf(listOf("d", "nv-private-copy:x"))))
    }

    private fun <T> assertNotNullAnd(v: T?): T { assertNotNull(v); return v!! }
}
