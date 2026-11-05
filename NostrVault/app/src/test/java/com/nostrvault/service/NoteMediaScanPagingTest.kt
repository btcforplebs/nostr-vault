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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Import media reads every one of your notes, not just the newest 250: the
 * local store answers a plain query with at most 250, which used to end the
 * scan after its first page (Ted, 2026-11-05).
 */
class NoteMediaScanPagingTest {
    private val owner = "1".repeat(64)
    private val stranger = "2".repeat(64)

    private fun note(i: Int, pubkey: String = owner, createdAt: Long = 1_700_000_000L + i): JsonObject = buildJsonObject {
        put("id", i.toString().padStart(64, '0'))
        put("pubkey", pubkey)
        put("created_at", createdAt)
        put("kind", 1)
        put("content", "photo $i https://blossom.example/${i.toString(16).padStart(64, '0')}.jpg")
        putJsonArray("tags") {}
    }

    /** The local store: newest first, `until` inclusive, never more than [cap] per answer. */
    private fun store(events: List<JsonObject>, cap: Int = 250): suspend (String) -> List<JsonObject> = { filter ->
        val f = Json.parseToJsonElement(filter).jsonObject
        val until = f["until"]?.jsonPrimitive?.longOrNull
        val limit = minOf(cap, f["limit"]!!.jsonPrimitive.longOrNull!!.toInt())
        events.filter { until == null || it["created_at"]!!.jsonPrimitive.longOrNull!! <= until }
            .sortedByDescending { it["created_at"]!!.jsonPrimitive.longOrNull!! }
            .take(limit)
    }

    @Test
    fun `more than 250 owner notes are all read, down to the oldest`() = runBlocking {
        val events = (0 until 600).map { note(it) }
        var pages = 0
        val fetch = store(events)
        val notes = NoteMediaScan.collect(owner) { pages++; fetch(it) }

        assertEquals(600, notes.size)
        assertEquals(1_700_000_000L, notes.minOf { it.createdAt })
        // 250 + 250 + 100 new, then one page with nothing new ends it.
        assertEquals(4, pages)
        val urls = notes.flatMap { Regex("https://\\S+").findAll(it.content).map { m -> m.value }.toList() }
        val toImport = NoteMediaScan.urlsToImport(urls) { false }
        assertTrue("the oldest note's media is imported", "https://blossom.example/${0.toString(16).padStart(64, '0')}.jpg" in toImport)
        assertEquals(600, toImport.size)
    }

    @Test
    fun `notes sharing a second across a page edge are not lost`() = runBlocking {
        // 300 notes, every 3 in the same second: page edges fall inside a second.
        val events = (0 until 300).map { note(it, createdAt = 1_700_000_000L + it / 3) }
        assertEquals(300, NoteMediaScan.collect(owner, store(events)).size)
    }

    @Test
    fun `other authors' notes are left out and an empty store ends at once`() = runBlocking {
        val events = (0 until 10).map { note(it) } + (10 until 20).map { note(it, pubkey = stranger) }
        assertEquals(10, NoteMediaScan.collect(owner, store(events)).size)
        var pages = 0
        assertEquals(0, NoteMediaScan.collect(owner) { pages++; emptyList() }.size)
        assertEquals(1, pages)
    }
}
