package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The shared emoji-note fixtures (docs/fixtures/emoji-notes/): the same answers as the Apple and web PRs. */
class EmojiNotesFixtureTest {
    private val dir = File("../../docs/fixtures/emoji-notes")
    private val expected = Json.parseToJsonElement(File(dir, "expected.json").readText()).jsonObject

    private fun events(name: String): List<JsonObject> =
        Json.parseToJsonElement(File(dir, name).readText()).jsonArray.map { it.jsonObject }

    private fun strings(a: JsonArray) = a.map { it.jsonPrimitive.content }

    @Test
    fun everyFixtureGivesTheExpectedAnswer() {
        assertEquals(setOf("good.json", "two-codes.json", "missing-tags.json", "photo-and-emoji.json"), expected.keys)
        for ((name, want) in expected) {
            val w = want.jsonObject
            val index = EmojiNoteIndex()
            events(name).forEach { index.apply(it) }
            assertEquals(name, w["emojiNotes"]!!.jsonPrimitive.int, index.emojiNotes.size)
            assertEquals(name, strings(w["hiddenFromMedia"]!!.jsonArray).toSet(), index.hiddenFromMedia)
            for ((sha, codes) in w["codes"]!!.jsonObject) {
                assertEquals("$name codes", codes.jsonArray.map { strings(it.jsonArray) }, index.codes(sha))
            }
            for ((sha, sets) in w["sets"]!!.jsonObject) {
                assertEquals("$name sets", strings(sets.jsonArray), index.sets(sha))
            }
        }
    }

    @Test
    fun builtTagsReadBackTheSame() {
        val owner = "a".repeat(64)
        val sha = "1".repeat(64)
        val set = "30030:${"b".repeat(64)}:cats"
        val tags = EmojiNote.tags(sha, "image/png", 2048, owner, emptyList(),
            listOf("blobcat" to "https://cdn.example.com/x.png", "bad code!" to "https://x.example/y.png"),
            listOf(set, "10030:${"b".repeat(64)}:"))!!
        assertTrue(listOf("t", "nv-emoji") in tags)
        val event = Json.parseToJsonElement(
            """{"id":"e1","pubkey":"${"c".repeat(64)}","created_at":1,"kind":1063,"content":"","tags":${
                JsonArray(tags.map { t -> JsonArray(t.map { kotlinx.serialization.json.JsonPrimitive(it) }) })
            }}""",
        ).jsonObject
        val note = EmojiNote.parse(event)!!
        assertEquals(listOf(listOf("blobcat", "https://cdn.example.com/x.png")), note.codes)
        assertEquals(listOf(set), note.sets)
        assertNull(EmojiNote.tags("nothex", "image/png", 1, owner, emptyList(), emptyList(), emptyList()))
    }

    @Test
    fun aDeletionBringsTheImageBackOrDropsIt() {
        val index = EmojiNoteIndex()
        events("good.json").forEach { index.apply(it) }
        val del = Json.parseToJsonElement(
            """{"id":"d1","pubkey":"${"c".repeat(64)}","created_at":2,"kind":5,"content":"","tags":[["e","e100000000000000000000000000000000000000000000000000000000000000"],["k","1063"],["x","${"1".repeat(64)}"]]}""",
        ).jsonObject
        assertTrue(index.apply(del))
        assertEquals(emptySet<String>(), index.hiddenFromMedia)
        // The note replayed after its deletion stays gone.
        events("good.json").forEach { index.apply(it) }
        assertEquals(0, index.emojiNotes.size)
    }

    @Test
    fun anotherOwnersNotesDoNotCount() {
        val index = EmojiNoteIndex(owner = "f".repeat(64))
        events("good.json").forEach { index.apply(it) }
        assertEquals(0, index.emojiNotes.size)
    }
}
