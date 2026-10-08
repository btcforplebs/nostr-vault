package com.nostrvault.data.model

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS PostEngagementTests. */
class PostEngagementTest {
    private val post = "a".repeat(64)
    private val other = "b".repeat(64)
    private val alice = "1".repeat(64)
    private val bob = "2".repeat(64)

    private fun event(id: String, kind: Int, pubkey: String, tags: List<List<String>>, content: String = "") =
        EngagementEvent(id, kind, pubkey, content, tags)

    private fun tally(events: List<EngagementEvent>, vararg targets: String) =
        PostEngagementQuery.tally(events, targets.toSet())

    @Test fun `counts each kind against the right post`() {
        val events = listOf(
            event("r1", 7, alice, listOf(listOf("e", post), listOf("p", alice)), "+"),
            event("r2", 7, bob, listOf(listOf("e", post)), "🔥"),
            event("s1", 6, bob, listOf(listOf("e", post), listOf("p", alice))),
            event("z1", 9735, alice, listOf(listOf("e", post), listOf("bolt11", "lnbc2500u1pvjluez"))),
            event("z2", 9735, alice, listOf(listOf("e", post), listOf("bolt11", "lnbc10n1pvjluez"))),
            event("c1", 1, bob, listOf(listOf("e", post, "", "reply"))),
            event("c2", 1111, alice, listOf(listOf("E", post), listOf("e", post))),
        )
        assertEquals(PostEngagement(likes = 2, reposts = 1, replies = 2, zapSats = 250_001), tally(events, post)[post])
    }

    @Test fun `same event from two relays counts once`() {
        val zap = event("z1", 9735, alice, listOf(listOf("e", post), listOf("bolt11", "lnbc10n1pvjluez")))
        assertEquals(1L, tally(listOf(zap, zap), post)[post]?.zapSats)
    }

    @Test fun `one person reacting twice is one like`() {
        val events = listOf(
            event("r1", 7, alice, listOf(listOf("e", post)), "+"),
            event("r2", 7, alice, listOf(listOf("e", post)), "🤙"),
        )
        assertEquals(1, tally(events, post)[post]?.likes)
    }

    @Test fun `a dislike is not a like`() {
        assertNull(tally(listOf(event("r1", 7, alice, listOf(listOf("e", post)), "-")), post)[post])
    }

    @Test fun `a reaction counts only for its last e tag`() {
        // A reaction to a reply names the thread root first; it is not a like of the root.
        val t = tally(listOf(event("r1", 7, alice, listOf(listOf("e", post), listOf("e", other)), "+")), post, other)
        assertNull(t[post])
        assertEquals(1, t[other]?.likes)
    }

    @Test fun `a quote and a deeper reply are not replies`() {
        val events = listOf(
            event("q1", 1, alice, listOf(listOf("e", post, "", "mention"))),
            event("d1", 1, bob, listOf(listOf("e", post, "", "root"), listOf("e", other, "", "reply"))),
        )
        assertEquals(PostEngagement(quotes = 1), tally(events, post)[post])
    }

    @Test fun `counts both kinds of quote`() {
        val events = listOf(
            event("q1", 1, alice, listOf(listOf("q", post))),
            event("q2", 1, bob, listOf(listOf("e", post, "", "mention"))),
            event("q3", 1111, bob, listOf(listOf("E", other), listOf("e", other), listOf("q", post, "wss://r"))),
        )
        val t = tally(events + events, post, other)
        assertEquals(PostEngagement(quotes = 3), t[post])
        assertEquals(PostEngagement(replies = 1), t[other])
    }

    @Test fun `a reply that also quotes its parent is only a reply`() {
        val events = listOf(event("c1", 1, bob, listOf(listOf("e", post, "", "reply"), listOf("q", post))))
        assertEquals(PostEngagement(replies = 1), tally(events, post)[post])
    }

    @Test fun `one note quoting two posts counts for each`() {
        val t = tally(listOf(event("q1", 1, alice, listOf(listOf("q", post), listOf("q", other)))), post, other)
        assertEquals(1, t[post]?.quotes)
        assertEquals(1, t[other]?.quotes)
    }

    @Test fun `an event for another post is ignored`() {
        assertTrue(tally(listOf(event("r1", 7, alice, listOf(listOf("e", other)), "+")), post).isEmpty())
    }

    @Test fun `a zap without a readable amount adds nothing`() {
        val events = listOf(event("z1", 9735, alice, listOf(listOf("e", post), listOf("bolt11", "lnbc1pvjluez"))))
        assertNull(tally(events, post)[post])
    }

    // ── Filters ──────────────────────────────────────────────────────

    private fun parse(filter: String) = Json.parseToJsonElement(filter) as kotlinx.serialization.json.JsonObject
    private fun list(filter: String, key: String) =
        (parse(filter)[key] as? kotlinx.serialization.json.JsonArray)?.map { it.toString().trim('"') }

    @Test fun `filters split ids into groups and ask by q tag too`() {
        val ids = (0 until 23).map { it.toString().padStart(64, '0') }
        val filters = PostEngagementQuery.filters(ids, groupSize = 10)
        assertEquals(listOf(10, 10, 3), filters.mapNotNull { list(it, "#e")?.size })
        assertEquals(listOf(10, 10, 3), filters.mapNotNull { list(it, "#q")?.size })
        assertEquals(ids.toSet(), filters.flatMap { list(it, "#e").orEmpty() }.toSet())
        assertEquals(listOf("7", "6", "16", "9735", "1", "1111"), list(filters[0], "kinds"))
        assertEquals(listOf("1", "1111"), list(filters[1], "kinds"))
    }

    @Test fun `follow-up filters carry since`() {
        val filters = PostEngagementQuery.filters(listOf(post), since = 1_791_000_000)
        assertEquals(2, filters.size)
        filters.forEach { assertEquals("1791000000", parse(it)["since"].toString()) }
        assertNull(parse(PostEngagementQuery.filters(listOf(post))[0])["since"])
    }

    // ── Display ──────────────────────────────────────────────────────

    @Test fun `a lower bound gets its plus only from ten`() {
        val e = PostEngagement(likes = 64, reposts = 3, replies = 10, zapSats = 2_100, isLowerBound = true)
        assertTrue(e.isAtLeast(e.likes.toLong()))
        assertFalse(e.isAtLeast(e.reposts.toLong()))
        assertTrue(e.isAtLeast(e.replies.toLong()))
        assertFalse(e.copy(isLowerBound = false).isAtLeast(64))
    }

    // ── Ledger (kept between visits) ─────────────────────────────────

    @Test fun `a second visit adds only what is new`() {
        val firstVisit = listOf(
            event("r1", 7, alice, listOf(listOf("e", post)), "+"),
            event("z1", 9735, alice, listOf(listOf("e", post), listOf("bolt11", "lnbc10n1pvjluez"))),
        )
        // The relay hands back the same like and zap again, plus one new like.
        val secondVisit = firstVisit + event("r2", 7, bob, listOf(listOf("e", post)), "+")
        val ledger = EngagementLedger()
            .absorbing(PostEngagementQuery.contributions(firstVisit, setOf(post))[post]!!)
            .absorbing(PostEngagementQuery.contributions(secondVisit, setOf(post))[post]!!)
        assertEquals(2, ledger.engagement.likes)
        assertEquals(1L, ledger.engagement.zapSats)
    }

    @Test fun `the same person liking again later is still one like`() {
        val ledger = EngagementLedger()
            .absorbing(PostEngagementQuery.contributions(listOf(event("r1", 7, alice, listOf(listOf("e", post)), "+")), setOf(post))[post]!!)
            .absorbing(PostEngagementQuery.contributions(listOf(event("r9", 7, alice, listOf(listOf("e", post)), "🔥")), setOf(post))[post]!!)
        assertEquals(1, ledger.engagement.likes)
    }

    @Test fun `a ledger survives save and load`() {
        val ledger = EngagementLedger().absorbing(PostEngagementQuery.contributions(listOf(
            event("r1", 7, alice, listOf(listOf("e", post)), "+"),
            event("z1", 9735, bob, listOf(listOf("e", post), listOf("bolt11", "lnbc2500u1pvjluez"))),
        ), setOf(post))[post]!!).copy(checkedAt = 1_791_000_000, isLowerBound = false)
        val back = Json.decodeFromString<Map<String, EngagementLedger>>(Json.encodeToString(mapOf(post to ledger)))
        assertEquals(ledger, back[post])
        assertEquals(PostEngagement(likes = 1, zapSats = 250_000), back[post]?.engagement)
    }

    @Test fun `ledger keys are short prefixes`() {
        val ledger = EngagementLedger().absorbing(PostEngagementQuery.contributions(
            listOf(event("f".repeat(64), 1, alice, listOf(listOf("e", post, "", "reply")))), setOf(post),
        )[post]!!)
        assertEquals(setOf("f".repeat(16)), ledger.replies)
        assertEquals(emptySet<String>(), ledger.likers)
    }

    @Test fun `reads an event straight off the relay JSON`() {
        val json = buildJsonObject {
            put("id", "r1"); put("kind", 7); put("pubkey", alice); put("content", "+")
            put("tags", buildJsonArray { add(buildJsonArray { add(kotlinx.serialization.json.JsonPrimitive("e")); add(kotlinx.serialization.json.JsonPrimitive(post)) }) })
        }
        assertEquals(event("r1", 7, alice, listOf(listOf("e", post)), "+"), EngagementEvent.from(json))
        assertNull(EngagementEvent.from(buildJsonObject { put("id", "x") }))
    }
}
