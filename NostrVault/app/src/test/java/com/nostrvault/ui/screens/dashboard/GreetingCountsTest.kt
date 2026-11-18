package com.nostrvault.ui.screens.dashboard

import com.nostrvault.ui.screens.dashboard.GreetingCounts.Greeting
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GreetingCountsTest {
    private val g = GreetingCounts
    private val me = "aa".repeat(32)
    private val other = "bb".repeat(32)

    private fun note(id: String, content: String, at: Long, kind: Int = 1, pubkey: String = me): JsonObject =
        Json.parseToJsonElement(
            """{"id":"$id","pubkey":"$pubkey","kind":$kind,"created_at":$at,"content":${Json.encodeToString(String.serializer(), content)}}""",
        ).jsonObject

    @Test fun `plain greetings count as GM`() {
        for (s in listOf("gm", "GM", "gm!", "Gm.", "Good Morning", "good morning!!", "GOOD MORNING", "gmgm", "gmmm", "gm ☕", "  gm\n")) {
            assertEquals(s, setOf(Greeting.GM), g.greetings(s))
        }
    }

    @Test fun `pura vida and PV get their own greeting`() {
        for (s in listOf("Pura Vida", "pura vida!", "PV", "pv 🌴")) {
            assertEquals(s, setOf(Greeting.PURA_VIDA), g.greetings(s))
        }
        assertEquals(setOf(Greeting.GM, Greeting.PURA_VIDA), g.greetings("GM, pura vida"))
    }

    @Test fun `a greeting with a couple of words, a photo or a tag still counts`() {
        for (s in listOf("gm nostr", "Good morning everyone, frens", "gm https://image.example/a.jpg", "#gm gm", "gm nostr:npub1xyz", "gm #coffee")) {
            assertEquals(s, setOf(Greeting.GM), g.greetings(s))
        }
    }

    @Test fun `a note that only contains gm does not count`() {
        for (s in listOf(
            "gm, today we ship the new relay build",
            "I said gm to everyone at the meetup",
            "the gm of the hotel was great tonight",
            "good",
            "morning",
            "programming",
            "pvc pipes",
            "",
            "https://example.com/gm",
            "#gm",
        )) {
            assertEquals(s, emptySet<Greeting>(), g.greetings(s))
        }
    }

    @Test fun `counts only my kind 1 notes, today and all time, once per id`() {
        val today = 1_000_000L
        val notes = listOf(
            note("1", "gm", today + 10),
            note("2", "GM!", today - 10),
            note("2", "GM!", today - 10), // the same note twice
            note("3", "Pura Vida", today + 5),
            note("4", "pv", today - 100),
            note("5", "gm pura vida", today - 200),
            note("6", "gm, here is a long update about the release", today + 1),
            note("7", "gm", today + 1, pubkey = other),
            note("8", "gm", today + 1, kind = 7),
        )
        assertEquals(GreetingCounts.Counts(gmToday = 1, gmAll = 3, pvToday = 1, pvAll = 3), g.count(notes, me, today))
    }

    @Test fun `reads every page back with until and stops when nothing new comes`() {
        // 5 notes, two at the same second on a page edge.
        val all = listOf(note("e", "gm", 50), note("d", "gm", 40), note("c", "gm", 30), note("b", "gm", 30), note("a", "gm", 10))
        val filters = mutableListOf<String>()
        val got = g.readAll(me, pageSize = 2, maxPages = 10) { filter ->
            filters += filter
            val until = Regex("\"until\":(\\d+)").find(filter)?.groupValues?.get(1)?.toLong() ?: Long.MAX_VALUE
            all.filter { (it["created_at"].toString().toLong()) <= until }.take(2)
        }!!
        assertEquals(listOf("e", "d", "c", "b", "a"), got.map { it["id"].toString().trim('"') })
        assertTrue(filters.first().contains("\"kinds\":[1]") && filters.first().contains("\"authors\":[\"$me\"]"))
        assertTrue(!filters.first().contains("until"))
    }

    @Test fun `no store answer means no counts`() {
        assertNull(g.readAll(me, pageSize = 2, maxPages = 3) { null })
    }

    @Test fun `label reads GM then PV`() {
        assertEquals("GM 12 · PV 3", g.label(12, 3) { it.toString() })
    }
}
