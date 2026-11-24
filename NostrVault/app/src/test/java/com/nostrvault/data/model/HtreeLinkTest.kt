package com.nostrvault.data.model

import com.nostrvault.ui.components.ContentSegment
import com.nostrvault.ui.components.parseContentSegments
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * htree:// (Iris hashtree) photo links, phase 1: one CHK blob up to 2 MiB.
 * Fixture: docs/HTREE_VECTORS.json (byte-identical in web, Apple and Android
 * tests): the real note b467f19b (MaxisClub) that started this, hashtree's CHK
 * interop vectors, and small end-to-end blobs. Web: test/htree.test.mjs (#2508).
 */
class HtreeLinkTest {
    private val doc = Json.parseToJsonElement(
        javaClass.classLoader!!.getResource("htree/HTREE_VECTORS.json")!!.readText(),
    ).jsonObject
    private val note = doc["note"]!!.jsonObject
    private val event = note["event"]!!.jsonObject

    private fun JsonObject.s(k: String) = this[k]!!.jsonPrimitive.content
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    @Test
    fun `the fixture note's link reads as blob hash, CHK v1 key and file name`() {
        // The event id is the sha256 of its NIP-01 serialization: this is the real note, unedited.
        val tags = event["tags"]!!.jsonArray.joinToString(",", "[", "]") { t -> t.jsonArray.joinToString(",", "[", "]") { Json.encodeToString(kotlinx.serialization.json.JsonPrimitive.serializer(), it.jsonPrimitive) } }
        val content = Json.encodeToString(kotlinx.serialization.json.JsonPrimitive.serializer(), event["content"]!!.jsonPrimitive)
        val serial = """[0,"${event.s("pubkey")}",${event["created_at"]!!.jsonPrimitive.long},${event["kind"]!!.jsonPrimitive.content},$tags,$content]"""
        assertEquals(event.s("id"), HtreeLink.sha256Hex(serial.toByteArray()))

        val link = HtreeLink.parse(note.s("link"))!!
        assertEquals(note.s("blobHash"), link.blobHash)
        assertEquals(note.s("plainSha256"), link.plainSha256)
        assertEquals(note.s("key").substring(2), link.chk.hex())
        assertEquals(note.s("name"), link.name)
        assertEquals(note.s("ext"), link.ext)
        assertEquals(33, HtreeLink.decodeNhash(note.s("link").removePrefix("htree://").substringBefore('/'))!!.second!!.size)
    }

    @Test
    fun `the fixture note's photo is media, and its link leaves the text`() {
        val text = event.s("content")
        val media = FeedNote.parseMediaURLs(text)
        assertEquals(listOf(note.s("link")), media)
        val segments = parseContentSegments(text, media.toSet())
        assertEquals(listOf(ContentSegment.PlainText("1692. Myself")), segments)
    }

    @Test
    fun `hashtree's CHK interop vectors decrypt, and a wrong key gives nothing`() {
        for (v in doc["chk"]!!.jsonArray.map { it.jsonObject }) {
            assertArrayEquals(v.s("name"), hex(v.s("plain")), HtreeLink.decryptChk(hex(v.s("ciphertext")), hex(v.s("key"))))
            assertNull(v.s("name"), HtreeLink.decryptChk(hex(v.s("ciphertext")), ByteArray(32)))
        }
    }

    @Test
    fun `only CHK links are read - rnd-v1, no key, a bad checksum or another bech32 stay text`() {
        for (v in doc["notShown"]!!.jsonArray.map { it.jsonObject }) {
            assertNull(v.s("name"), HtreeLink.parse(v.s("link")))
            assertFalse(v.s("name"), HtreeLink.isPhotoLink(v.s("link")))
            assertTrue(v.s("name"), FeedNote.parseMediaURLs("look ${v.s("link")}").isEmpty())
        }
    }

    @Test
    fun `end to end - checked, decrypted, checked again, opened only when it is a picture`() {
        for (v in doc["e2e"]!!.jsonArray.map { it.jsonObject }) {
            val link = HtreeLink.parse(v.s("link"))!!
            assertEquals(v.s("blobHash"), link.blobHash)
            assertEquals(v.s("plainSha256"), link.plainSha256)
            val opened = HtreeLink.open(link, hex(v.s("blob")))
            if (v["show"]!!.jsonPrimitive.content == "true") {
                assertNotNull(v.s("name"), opened)
                assertArrayEquals(v.s("name"), hex(v.s("plain")), opened!!.bytes)
                assertEquals(v.s("mime"), opened.mime)
            } else {
                assertNull(v.s("name"), opened)
            }
        }
    }

    @Test
    fun `a tampered blob, or a link claiming another plain hash, is never opened`() {
        val v = doc["e2e"]!!.jsonArray[0].jsonObject
        val link = HtreeLink.parse(v.s("link"))!!
        val tampered = hex(v.s("blob")).also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertNull(HtreeLink.open(link, tampered))
        assertNull(HtreeLink.open(link.copy(chk = ByteArray(32) { 9 }), hex(v.s("blob"))))
        assertNull(HtreeLink.open(link, ByteArray((HtreeLink.MAX_BLOB_BYTES + 1).toInt())))
    }

    @Test
    fun `servers - Iris first, then the author's, then ours, public https only, eight at most`() {
        assertEquals(
            listOf("https://upload.iris.to", "https://a.example", "https://b.example"),
            HtreeLink.servers(listOf("https://a.example/"), listOf("b.example", "http://192.168.1.2", "https://upload.iris.to")),
        )
        assertEquals(8, HtreeLink.servers((1..20).map { "s$it.example" }, emptyList()).size)
        val link = HtreeLink.parse(note.s("link"))!!
        assertEquals("https://upload.iris.to/${note.s("blobHash")}", link.candidates(emptyList(), emptyList()).single())
    }

    @Test
    fun `sniffImage knows the picture types and nothing else`() {
        assertEquals("image/jpeg", HtreeLink.sniffImage(hex("ffd8ffe0")))
        assertEquals("image/png", HtreeLink.sniffImage(hex("89504e470d0a1a0a00")))
        assertEquals("image/gif", HtreeLink.sniffImage("GIF89a..".toByteArray()))
        assertEquals("image/webp", HtreeLink.sniffImage("RIFF....WEBPVP8 ".toByteArray()))
        assertNull(HtreeLink.sniffImage("<svg>".toByteArray()))
        assertNull("a hashtree tree node is not a picture", HtreeLink.sniffImage(hex("82a16c90a17402")))
    }

    @Test
    fun `a link named as a video stays text in phase 1`() {
        val v = doc["e2e"]!!.jsonArray[0].jsonObject
        assertFalse(HtreeLink.isPhotoLink(v.s("link").replace("/dot.jpg", "/clip.mp4")))
        assertTrue(HtreeLink.isPhotoLink(v.s("link").substringBefore("/dot.jpg")))
    }

    /** HTREE_REAL_BLOB=<upload.iris.to/<blobHash> saved>: the real 948,296-byte blob opens to the 948,280-byte JPEG. */
    @Test
    fun `the real photo opens when its blob is given`() {
        val path = System.getenv("HTREE_REAL_BLOB")
        assumeTrue(path != null && File(path).exists())
        val opened = HtreeLink.open(HtreeLink.parse(note.s("link"))!!, File(path!!).readBytes())!!
        assertEquals(note["plainBytes"]!!.jsonPrimitive.long, opened.bytes.size.toLong())
        assertEquals("image/jpeg", opened.mime)
    }
}
