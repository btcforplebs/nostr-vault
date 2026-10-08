package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS TrustPathTests and TrustMapTests. */
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

class TrustMapTest {

    private val me = "0".repeat(64)
    private val author = "a".repeat(64)

    private fun key(n: Int) = String.format("%064x", n.toLong() * 0x1234567 + 1)

    private fun list(signer: String, tags: List<String>, at: Long = 0) =
        ContactList(signer, at, tags.map { listOf("p", it) })

    @Test fun `angle comes from the key and stays put`() {
        assertEquals(0.0, TrustMap.angle("00000000" + "f".repeat(56)), 0.0)
        assertEquals(180.0, TrustMap.angle("80000000" + "f".repeat(56)), 0.0)
        val k = key(42)
        assertEquals(TrustMap.angle(k), TrustMap.angle(k), 0.0)
        val odd = TrustMap.angle("not-a-key")
        assertEquals(odd, TrustMap.angle("not-a-key"), 0.0)
        assertTrue(odd >= 0 && odd < 360)
    }

    @Test fun `band stays within one`() {
        for (n in 0 until 200) assertTrue(TrustMap.band(key(n)) in -1.0..1.0)
    }

    @Test fun `spread picks evenly through the list`() {
        val keys = (0 until 48).map(::key)
        assertEquals(listOf(keys[0], keys[12], keys[24], keys[36]), TrustMap.spread(keys, 4))
        assertEquals(keys.take(3), TrustMap.spread(keys.take(3), 12))
        assertEquals(keys, TrustMap.spread(keys, 0))
    }

    @Test fun `next batch skips seen and the author`() {
        val filters = TrustMap.nextBatch(author, listOf(key(1), key(2), author, key(3)), setOf(key(2)))
        assertEquals(1, filters.size)
        assertEquals(listOf(key(1), key(3)), filters[0].authors)
        assertEquals(listOf(author), filters[0].tagged)
        assertEquals(TrustMap.BATCH_SIZE, filters[0].limit)
        assertTrue(TrustMap.nextBatch(author, listOf(key(1), author), setOf(key(1))).isEmpty())
        val many = (1..2500).map(::key)
        assertEquals(listOf(1000, 1000, 500), TrustMap.nextBatch(author, many, emptySet(), 1000).map { it.authors!!.size })
    }

    @Test fun `follows of uses only the owner's newest list`() {
        val owner = key(7)
        val lists = listOf(
            list(owner, listOf(key(1)), at = 100),
            list(owner, listOf(key(2), key(2), owner, "short"), at = 200),
            list(key(8), listOf(key(9)), at = 300),
        )
        assertEquals(listOf(key(2)), TrustMap.follows(owner, lists))
        assertNull(TrustMap.follows(key(5), lists))
    }

    @Test fun `all bridges is uncapped`() {
        val follows = (1..9).map(::key).toSet()
        val lists = follows.map { list(it, listOf(author)) }
        val all = TrustPath.allBridges(author, me, follows, lists)
        assertEquals(follows.sorted(), all)
        assertEquals(all.take(5), TrustPath.resolve(author, me, follows, setOf("x"), lists).bridges)
    }

    @Test fun `deeper chains`() {
        val bridge = key(1); val other = key(2); val via = key(3); val stranger = key(4)
        val follows = setOf(bridge, other)
        // A follow's list is not a middle step (that's 2 hops), and neither is your own.
        val seeds = listOf(list(via, listOf(author)), list(stranger, listOf(author)),
            list(bridge, listOf(author)), list(me, listOf(author)))
        val viaList = TrustMap.deeperVia(author, me, follows, setOf(stranger), seeds)
        assertEquals("people in your graph come first", listOf(stranger, via), viaList)

        val filters = TrustMap.deeperLinkFilters(follows.sorted(), viaList)
        assertEquals(1, filters.size)
        assertEquals(viaList, filters[0].tagged)

        // A stranger's list can't invent a route; only your follows' lists count.
        val links = listOf(list(bridge, listOf(via, key(9))), list(other, listOf(stranger, via)), list(key(5), listOf(via)))
        assertEquals(
            listOf(TrustMap.Chain(other, stranger), TrustMap.Chain(bridge, via), TrustMap.Chain(other, via))
                .sortedWith(compareBy({ it.via }, { it.bridge })),
            TrustMap.chains(me, follows, viaList, links),
        )
        assertTrue(TrustMap.deeperLinkFilters(listOf(bridge), emptyList()).isEmpty())
    }
}
