package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Media import's scan of your notes for outside media links (iOS mirrorFromNoteMedia). */
class NoteMediaScanTest {
    private val hash = "a".repeat(64)

    @Test
    fun `outside links are imported once each, in order`() {
        val urls = listOf(
            "https://nostr.build/i/x.jpg",
            "https://image.nostr.build/y.png",
            "https://nostr.build/i/x.jpg",
        )
        assertEquals(listOf("https://nostr.build/i/x.jpg", "https://image.nostr.build/y.png"), NoteMediaScan.urlsToImport(urls) { false })
    }

    @Test
    fun `links to this device are skipped`() {
        val urls = listOf("http://localhost:3335/$hash.jpg", "http://127.0.0.1/a.png", "http://0.0.0.0/b.mp4")
        assertEquals(emptyList<String>(), NoteMediaScan.urlsToImport(urls) { false })
    }

    @Test
    fun `a hash-named file already stored here is skipped, others are kept`() {
        val stored = "https://blossom.primal.net/$hash.jpg"
        val missing = "https://blossom.primal.net/${"b".repeat(64)}.mp4"
        assertEquals(listOf(missing), NoteMediaScan.urlsToImport(listOf(stored, missing)) { it == hash })
    }

    @Test
    fun `the blob hash comes from a Blossom-style name only`() {
        assertEquals(hash, NoteMediaScan.blobHash("https://cdn.example/${hash.uppercase()}.webp"))
        assertEquals(hash, NoteMediaScan.blobHash("https://cdn.example/$hash"))
        assertNull(NoteMediaScan.blobHash("https://cdn.example/photo.jpg"))
        assertNull(NoteMediaScan.blobHash("https://cdn.example/${hash.dropLast(1)}.jpg"))
    }

    @Test
    fun `bad or non-web links are dropped`() {
        assertEquals(emptyList<String>(), NoteMediaScan.urlsToImport(listOf("ftp://x.example/a.jpg", "not a url", "https://")) { false })
    }

    @Test
    fun `the page filter asks for your notes and pages back with until`() {
        assertEquals("""{"kinds":[1],"authors":["ab"],"limit":1500}""", NoteMediaScan.pageFilter("ab", null))
        assertEquals("""{"kinds":[1],"authors":["ab"],"until":99,"limit":1500}""", NoteMediaScan.pageFilter("ab", 99))
    }

    @Test
    fun `a raw note parses, and one missing its id or time does not`() {
        val ok = Json.parseToJsonElement(
            """{"id":"e1","created_at":5,"pubkey":"ab","content":"hi","tags":[["url","https://x/y.jpg"]]}""",
        ).jsonObject
        assertEquals(NoteMediaScan.Note("e1", 5, "ab", "hi", listOf(listOf("url", "https://x/y.jpg"))), NoteMediaScan.parse(ok))
        assertNull(NoteMediaScan.parse(Json.parseToJsonElement("""{"created_at":5}""").jsonObject))
        assertNull(NoteMediaScan.parse(Json.parseToJsonElement("""{"id":"e1"}""").jsonObject))
    }
}
