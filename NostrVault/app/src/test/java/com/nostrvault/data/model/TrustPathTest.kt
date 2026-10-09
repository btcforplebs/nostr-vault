package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS TrustPathTests. */
class TrustPathTest {

    private val me = "me"
    private val author = "author"

    private fun list(signer: String, tags: List<String>, at: Long = 0, kind: Int = 3) =
        ContactList(signer, at, tags.map { listOf("p", it) }, kind)

    @Test fun `the author is you`() {
        val path = TrustPath.resolve(me, me, setOf("a"), setOf("a"), emptyList())
        assertEquals(TrustPath.Reach.YOU, path.reach)
    }

    @Test fun `a direct follow keeps its bridges`() {
        val path = TrustPath.resolve(author, me, setOf(author, "a"), setOf("x"), listOf(list("a", listOf(author))))
        assertEquals(TrustPath.Reach.FOLLOW, path.reach)
        assertEquals(listOf("a"), path.bridges)
    }

    @Test fun `bridges are sorted, capped and flag more`() {
        val follows = setOf("f", "e", "d", "c", "b", "a")
        val path = TrustPath.resolve(author, me, follows, setOf("x"), follows.map { list(it, listOf(author)) })
        assertEquals(TrustPath.Reach.BRIDGED, path.reach)
        assertEquals(listOf("a", "b", "c", "d", "e"), path.bridges)
        assertTrue(path.hasMore)
    }

    @Test fun `strangers, lists without the author and other kinds are ignored`() {
        val lists = listOf(list("stranger", listOf(author)), list("a", listOf("other")), list("b", listOf(author), kind = 1))
        val path = TrustPath.resolve(author, me, setOf("a", "b"), setOf(author), lists)
        assertEquals(TrustPath.Reach.WEB, path.reach)
        assertTrue(path.bridges.isEmpty())
        assertFalse(path.hasMore)
    }

    @Test fun `only each signer's newest list counts`() {
        val old = list("a", listOf(author), at = 100)
        val new = list("a", listOf("other"), at = 200)
        for (lists in listOf(listOf(old, new), listOf(new, old))) {
            assertEquals(TrustPath.Reach.OUTSIDE, TrustPath.resolve(author, me, setOf("a"), setOf("a"), lists).reach)
        }
    }

    @Test fun `outside needs a graph`() {
        assertEquals(TrustPath.Reach.OUTSIDE, TrustPath.resolve(author, me, setOf("a"), setOf("a"), emptyList()).reach)
        assertEquals(TrustPath.Reach.UNKNOWN, TrustPath.resolve(author, me, setOf("a"), emptySet(), emptyList()).reach)
    }

    @Test fun `filters chunk and skip the author`() {
        val follows = (0 until 501).map { "p$it" } + author
        val filters = TrustPath.filters(author, follows, chunkSize = 250)
        assertEquals(listOf(250, 250, 1), filters.map { it.authors!!.size })
        assertFalse(filters.any { author in it.authors!! })
        assertEquals(listOf(author), filters[0].tagged)
        assertEquals(TrustPath.LISTS_PER_FILTER, filters[0].limit)
        assertEquals(1, TrustPath.filters(author, follows.take(1000)).size)
    }

    @Test fun `filter json is a kind 3 REQ filter`() {
        val json = Json.parseToJsonElement(FollowListFilter(listOf("a"), listOf("b"), 6).toJson()).jsonObject
        assertEquals("[3]", json["kinds"].toString())
        assertEquals("[\"a\"]", json["authors"].toString())
        assertEquals("[\"b\"]", json["#p"].toString())
        assertEquals("6", json["limit"].toString())
        assertNull(Json.parseToJsonElement(TrustMap.deeperSeedFilter("b").toJson()).jsonObject["authors"])
    }

    @Test fun `contact list parses a relay event`() {
        val event = Json.parseToJsonElement(
            """{"id":"x","pubkey":"a","kind":3,"created_at":5,"tags":[["p","b"],["t","x"]],"content":""}""",
        ).jsonObject
        assertEquals(ContactList("a", 5, listOf(listOf("p", "b"), listOf("t", "x"))), ContactList.from(event))
    }

    @Test fun `label names two bridges then more`() {
        val name = { k: String -> k.uppercase() }
        assertEquals("Followed by A and B you follow · 2 hops",
            TrustPathText.label(TrustPath(TrustPath.Reach.BRIDGED, listOf("a", "b"), false), name))
        assertEquals("Followed by A, B + more you follow · 2 hops",
            TrustPathText.label(TrustPath(TrustPath.Reach.BRIDGED, listOf("a", "b", "c"), false), name))
        assertEquals("Tracing how they reach you…", TrustPathText.label(null, name))
    }
}
