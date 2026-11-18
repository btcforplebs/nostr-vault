package com.nostrvault.service

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Copy reads your notes a page at a time and keeps only the links to copy (Moto out of memory, 2026-11-17). */
class NoteMediaScanPageByPageTest {
    private val owner = "1".repeat(64)

    private fun note(i: Int, createdAt: Long) = buildJsonObject {
        put("id", i.toString().padStart(64, '0'))
        put("pubkey", owner)
        put("created_at", createdAt)
        put("kind", 1)
        put("content", "photo $i")
        putJsonArray("tags") {}
    }

    private fun store(events: List<JsonObject>, cap: Int): suspend (String) -> List<JsonObject> = { filter ->
        val f = Json.parseToJsonElement(filter).jsonObject
        val until = f["until"]?.jsonPrimitive?.longOrNull
        events.filter { until == null || it["created_at"]!!.jsonPrimitive.longOrNull!! <= until }
            .sortedByDescending { it["created_at"]!!.jsonPrimitive.longOrNull!! }
            .take(cap)
    }

    @Test
    fun `every note comes once, across pages that share a second at the edge`() = runBlocking {
        // Three notes per second, so every page edge splits a second.
        val events = (0 until 700).map { note(it, 1_700_000_000L + it / 3) }
        val seen = mutableListOf<String>()
        var biggest = 0
        val read = NoteMediaScan.forEachPage(owner, store(events, cap = 250)) { page ->
            biggest = maxOf(biggest, page.size); seen += page.map { it.id }; true
        }
        assertEquals(700, read)
        assertEquals(700, seen.size)
        assertEquals(700, seen.toSet().size)
        assertTrue("one page at a time, never the whole history", biggest <= 250)
    }

    @Test
    fun `onPage false stops the read`() = runBlocking {
        val events = (0 until 700).map { note(it, 1_700_000_000L + it) }
        var pages = 0
        val read = NoteMediaScan.forEachPage(owner, store(events, cap = 250)) { pages++; false }
        assertEquals(1, pages)
        assertEquals(250, read)
    }

    @Test
    fun `the picker takes each outside link once and skips what is stored here`() {
        val stored = "a".repeat(64)
        val picker = NoteMediaScan.Picker { it == stored }
        assertTrue(picker.offer("https://x.example/one.jpg"))
        assertFalse(picker.offer("https://x.example/one.jpg"))
        assertFalse(picker.offer("https://blossom.example/$stored.jpg"))
        assertFalse(picker.offer("http://127.0.0.1:3355/b.jpg"))
        val other = "b".repeat(64)
        assertTrue(picker.offer("https://one.example/$other.png"))
        assertFalse("the same file on another server", picker.offer("https://two.example/$other.png"))
    }
}
