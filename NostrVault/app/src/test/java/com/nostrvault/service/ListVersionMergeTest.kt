package com.nostrvault.service

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Merge rules for old list versions: entries compare by type and value (Lazarus delta rule), the current list is
 * always in the merge, a duplicate keeps the current form, private in any version stays private, an entry removed in
 * an ordinary edit comes back unticked while one lost to a wipe comes back ticked, empty versions can't be picked,
 * and nothing merges a relay list. Port of web-vault/test/list-version-merge.test.mjs, case for case. The private
 * parts use a stand-in cipher (the NIP-44 code is native): what is tested is when a version is opened, not the crypto.
 */
class ListVersionMergeTest {
    private val me = "f".repeat(64)
    private var serial = 0

    private fun p(n: Int) = n.toString(16).padStart(64, '0')

    private fun ev(kind: Int, tags: List<List<String>>, at: Long, content: String = ""): ListVersion {
        serial++
        return ListVersion("id%04d".format(serial), me, kind, at, tags, content)
    }

    private fun enc(tags: List<List<String>>): String =
        "c:" + Base64.getEncoder().encodeToString(JsonArray(tags.map { t -> JsonArray(t.map(::JsonPrimitive)) }).toString().toByteArray())

    private fun dec(c: String): String {
        require(c.startsWith("c:")) { "not ciphertext" }
        return String(Base64.getDecoder().decode(c.removePrefix("c:")))
    }

    private val open = ListVersionMerge.Opener.With { dec(it) }

    private fun follows(ns: List<Int>, at: Long, extra: List<List<String>> = emptyList()) =
        ev(3, ns.map { listOf("p", p(it)) } + extra, at, """{"relays":"keep"}""")

    private suspend fun opened(v: ListVersion, opener: ListVersionMerge.Opener = open) = ListVersionMerge.openVersion(v, opener)

    private fun List<ListVersionMerge.Row>.of(value: String) = first { it.tag[1] == value }

    @Test
    fun `entries compare by type and value - hints, petnames, case and relay spelling are the same entry`() {
        assertEquals(ListVersionMerge.itemKey(3, listOf("p", p(1).uppercase(), "wss://hint")), ListVersionMerge.itemKey(3, listOf("p", p(1), "", "alice")))
        assertEquals(
            ListVersionMerge.itemKey(10050, listOf("relay", "wss://Relay.Example:443//a/")),
            ListVersionMerge.itemKey(10050, listOf("relay", "wss://relay.example/a")),
        )
        assertEquals("wss://relay.example", ListVersionMerge.normUrl("WSS://Relay.Example/"))
        assertEquals("wss://relay.example:7777", ListVersionMerge.normUrl("wss://relay.example:7777/"))
        assertNull("a tag naming the list is not an entry", ListVersionMerge.itemKey(3, listOf("d", "x")))
        assertNull("a tag with no value is not an entry", ListVersionMerge.itemKey(3, listOf("p")))
        assertNotEquals(ListVersionMerge.itemKey(10000, listOf("t", "x")), ListVersionMerge.itemKey(10000, listOf("word", "x")))
    }

    @Test
    fun `the wipe rule matches haven-go listShrank`() {
        val ten = follows((1..10).toList(), 1)
        assertTrue("emptied", ListShrinkRule.shrank(ten, follows(emptyList(), 2)))
        assertTrue("under half of 10+", ListShrinkRule.shrank(ten, follows(listOf(1, 2, 3, 4), 2)))
        assertFalse("exactly half is an edit", ListShrinkRule.shrank(ten, follows(listOf(1, 2, 3, 4, 5), 2)))
        assertFalse("a small list edited down is not a wipe", ListShrinkRule.shrank(follows(listOf(1, 2, 3, 4), 1), follows(listOf(1), 2)))
        assertTrue("encrypted part halved", ListShrinkRule.shrank(ev(10000, emptyList(), 1, "x".repeat(1200)), ev(10000, emptyList(), 2, "x".repeat(500))))
    }

    @Test
    fun `a version's private part is opened - an entry public and private is one private entry`() = runTest {
        val m = ev(10000, listOf(listOf("p", p(1)), listOf("t", "spam")), 10, enc(listOf(listOf("p", p(1)), listOf("word", "Scam"))))
        val v = opened(m)
        assertEquals("", v.reason)
        assertEquals(3, v.entries.size)
        assertEquals(true, v.entries[ListVersionMerge.itemKey(10000, listOf("p", p(1)))]?.private)
        val shut = opened(m, ListVersionMerge.Opener.None)
        assertTrue(shut.reason, shut.reason.contains("can't open"))
        assertFalse("an unopened private part may hold anything: not empty", shut.isEmpty)
        assertTrue(ListVersionMerge.pickProblem(shut).startsWith("Can't be merged"))
        val bad = opened(ev(10000, emptyList(), 10, "not-ciphertext"))
        assertTrue(bad.reason, bad.reason.contains("couldn't be opened"))
        val refused = opened(m, ListVersionMerge.Opener.With { null })
        assertTrue("a signer that can't open it: couldn't be opened", refused.reason.contains("couldn't be opened"))
        assertFalse("kind 3 content is relay hints, never a private part", ListVersionMerge.hasPrivate(follows(listOf(1), 1)))
        assertNull("only Settings › Relays sends a 10002", ListVersionMerge.mergeKind(10002))
        assertNull("no profile", ListVersionMerge.mergeKind(0))
        assertNull("no sets", ListVersionMerge.mergeKind(30000))
    }

    @Test
    fun `empty versions are never offered`() = runTest {
        val v = opened(follows(emptyList(), 5))
        assertTrue(v.isEmpty)
        assertTrue(ListVersionMerge.pickProblem(v).startsWith("Empty"))
    }

    @Test
    fun `merge - current always in, each entry once, current form wins, delta per version`() = runTest {
        val cur = opened(follows(listOf(1, 2), 30, listOf(listOf("p", p(1), "wss://now-hint"))))
        val old = opened(ev(3, listOf(listOf("p", p(1), "wss://old-hint"), listOf("p", p(3)), listOf("p", p(4))), 20))
        assertEquals(ListVersionMerge.Delta(added = 2, removed = 1), ListVersionMerge.deltaOf(old, cur))
        val rows = ListVersionMerge.buildMerge(cur, listOf(old), listOf(cur, old))
        assertEquals("current order first, then what comes back", listOf(p(1), p(2), p(3), p(4)), rows.map { it.tag[1] })
        assertEquals("the current list's own tag for 1 (its first p tag) is kept, not the old hint", 2, rows[0].tag.size)
        assertEquals(
            listOf(ListVersionMerge.Status.CURRENT, ListVersionMerge.Status.CURRENT, ListVersionMerge.Status.REMOVED, ListVersionMerge.Status.REMOVED),
            rows.map { it.status },
        )
    }

    @Test
    fun `a later remove - an ordinary edit comes back unticked, a wipe comes back ticked`() = runTest {
        val many = (1..12).toList()
        val v1 = opened(follows(many + 99, 10)) // had 99
        val v2 = opened(follows(many, 20)) // unfollowed 99: an edit
        val v3 = opened(follows(listOf(1), 30)) // a wipe: 12 -> 1
        val rows = ListVersionMerge.buildMerge(v3, listOf(v1, v2), listOf(v3, v2, v1))
        assertEquals(ListVersionMerge.Status.REMOVED, rows.of(p(99)).status)
        assertFalse("unfollowed on purpose: not brought back unless ticked", rows.of(p(99)).ticked)
        assertEquals(20L, rows.of(p(99)).at)
        assertEquals(ListVersionMerge.Status.LOST, rows.of(p(5)).status)
        assertTrue(rows.of(p(5)).ticked)
        assertEquals(30L, rows.of(p(5)).at)
        assertEquals(ListVersionMerge.Status.CURRENT, rows.of(p(1)).status)
        assertEquals(ListVersionMerge.Summary(total = 12, added = 11, removed = 0, remutes = 0), ListVersionMerge.mergeSummary(3, rows))
    }

    @Test
    fun `no current list - what comes back is ticked`() = runTest {
        val v1 = opened(follows(listOf(1, 2), 10))
        val v2 = opened(follows(listOf(2, 3), 20))
        val rows = ListVersionMerge.buildMerge(null, listOf(v1, v2), listOf(v2, v1))
        assertEquals("v2 dropped 1 in an edit", ListVersionMerge.Status.REMOVED, rows.of(p(1)).status)
        assertEquals(ListVersionMerge.Status.BACK, rows.of(p(3)).status)
    }

    @Test
    fun `private in any merged version stays private, and goes in the private tags`() = runTest {
        val cur = opened(ev(10000, listOf(listOf("p", p(1))), 30, enc(listOf(listOf("word", "x")))))
        val old = opened(ev(10000, listOf(listOf("t", "nsfw")), 20, enc(listOf(listOf("p", p(1)), listOf("p", p(2))))))
        val rows = ListVersionMerge.buildMerge(cur, listOf(old), listOf(cur, old)).map { it.copy(ticked = true) }
        assertTrue("public now, private before: kept private", rows.of(p(1)).private)
        val (tags, privateTags) = ListVersionMerge.mergedTags(rows, cur)
        assertEquals(listOf(listOf("t", "nsfw")), tags)
        assertEquals(listOf(p(1), p(2), "x").sorted(), privateTags.map { it[1] }.sorted())
        assertEquals("P(2) is muted again: said before Save", 1, ListVersionMerge.mergeSummary(10000, rows).remutes)
    }

    @Test
    fun `an unopenable older private part makes the next version's removal unknown, not a removal`() = runTest {
        val v1 = opened(ev(10000, emptyList(), 10, enc(listOf(listOf("p", p(7))))))
        val v2 = opened(ev(10000, listOf(listOf("p", p(1))), 20, "garbage"))
        val cur = opened(ev(10000, listOf(listOf("p", p(1)), listOf("p", p(2))), 30))
        val r = ListVersionMerge.buildMerge(cur, listOf(v1), listOf(cur, v2, v1)).of(p(7))
        assertEquals(ListVersionMerge.Status.BACK, r.status)
        assertTrue(r.ticked)
    }

    @Test
    fun `tags - the current list's own tags kept first, unticked rows dropped`() = runTest {
        val cur = opened(ev(10063, listOf(listOf("server", "https://a.example"), listOf("server", "https://b.example"), listOf("client", "x")), 30))
        val old = opened(ev(10063, listOf(listOf("server", "https://A.example/"), listOf("server", "https://c.example")), 20))
        val built = ListVersionMerge.buildMerge(cur, listOf(old), listOf(cur, old))
        assertEquals("a.example spelled two ways is one server", 3, built.size)
        val rows = built.map {
            when (it.tag[1]) {
                "https://b.example" -> it.copy(ticked = false)
                "https://c.example" -> it.copy(ticked = true)
                else -> it
            }
        }
        val (tags, privateTags) = ListVersionMerge.mergedTags(rows, cur)
        assertEquals(listOf(listOf("client", "x"), listOf("server", "https://a.example"), listOf("server", "https://c.example")), tags)
        assertEquals(emptyList<List<String>>(), privateTags)
        assertEquals(ListVersionMerge.Summary(total = 2, added = 1, removed = 1, remutes = 0), ListVersionMerge.mergeSummary(10063, rows))
    }

    @Test
    fun `one summary line per version`() {
        assertEquals("+340 follows, −2", ListVersionMerge.deltaLine(3, ListVersionMerge.Delta(340, 2)))
        assertEquals("+1 follow", ListVersionMerge.deltaLine(3, ListVersionMerge.Delta(1, 0)))
        assertEquals("−3 muted entries", ListVersionMerge.deltaLine(10000, ListVersionMerge.Delta(0, 3)))
        assertEquals("Same as now", ListVersionMerge.deltaLine(10003, ListVersionMerge.Delta(0, 0)))
    }

    @Test
    fun `an entry moved to the private part after the picked version comes back private`() = runTest {
        val v1 = opened(ev(10000, listOf(listOf("p", p(5)), listOf("p", p(6))), 10))
        val v2 = opened(ev(10000, listOf(listOf("p", p(6))), 20, enc(listOf(listOf("p", p(5))))))
        val cur = opened(ev(10000, emptyList(), 30)) // a wipe
        val rows = ListVersionMerge.buildMerge(cur, listOf(v1), listOf(cur, v2, v1))
        assertTrue(rows.of(p(5)).private)
        assertTrue(rows.of(p(5)).ticked)
        val (tags, privateTags) = ListVersionMerge.mergedTags(rows, cur)
        assertFalse("not in the public tags", tags.any { it[1] == p(5) })
        assertTrue(privateTags.any { it[1] == p(5) })
        assertFalse("an entry never private stays public", rows.of(p(6)).private)
    }

    @Test
    fun `a newer version not opened yet - what it may hide comes back private, nothing decrypted until asked`() = runTest {
        var asked = 0
        val counting = ListVersionMerge.Opener.With { asked++; dec(it) }
        val v1 = opened(ev(10000, listOf(listOf("p", p(5))), 10), counting)
        val v2 = opened(ev(10000, emptyList(), 20, enc(listOf(listOf("p", p(5))))), ListVersionMerge.Opener.Later)
        assertTrue(v2.locked)
        assertEquals("a locked version isn't decrypted", 0, asked)
        assertTrue("locked is not empty and can be ticked", !v2.isEmpty && ListVersionMerge.pickProblem(v2).isEmpty())
        val cur = opened(ev(10000, listOf(listOf("p", p(9))), 30), counting)
        val rows = ListVersionMerge.buildMerge(cur, listOf(v1), listOf(cur, v2, v1))
        assertTrue(rows.of(p(5)).private)
        assertFalse("the list now keeps its form", rows.of(p(9)).private)
        // An older unread version can't have hidden it later: no change.
        val v0 = opened(ev(10000, emptyList(), 5, enc(listOf(listOf("p", p(5))))), ListVersionMerge.Opener.Later)
        assertFalse(ListVersionMerge.buildMerge(cur, listOf(v1), listOf(cur, v1, v0)).of(p(5)).private)
    }

    @Test
    fun `an unmute in a newer locked version stays out once Merge opens it`() = runTest {
        var asked = 0
        val counting = ListVersionMerge.Opener.With { asked++; dec(it) }
        val later = ListVersionMerge.Opener.Later
        val v0 = opened(ev(10000, emptyList(), 5, enc(listOf(listOf("p", p(8))))), later)
        val v1 = opened(ev(10000, listOf(listOf("p", p(5))), 10), later)
        val v2 = opened(ev(10000, listOf(listOf("p", p(6))), 20, enc(listOf(listOf("word", "y")))), later) // unmuted P(5)
        val cur = opened(ev(10000, listOf(listOf("p", p(6))), 30, enc(listOf(listOf("word", "y")))), counting)
        asked = 0
        val all = ListVersionMerge.openForMerge(listOf(cur, v2, v1, v0), listOf(v1), counting)
        assertEquals("only the locked version newer than the oldest picked one is opened", 1, asked)
        assertTrue("an older one stays locked", all.first { it.v.id == v0.v.id }.locked)
        val x = ListVersionMerge.buildMerge(cur, listOf(all.first { it.v.id == v1.v.id }), all).of(p(5))
        assertEquals(ListVersionMerge.Status.REMOVED, x.status)
        assertFalse(x.ticked)
        assertFalse(x.private)
        // Without opening it, the same merge can't tell: it would come back.
        assertEquals(ListVersionMerge.Status.BACK, ListVersionMerge.buildMerge(cur, listOf(v1), listOf(cur, v2, v1, v0)).of(p(5)).status)
    }

    @Test
    fun `a locked version dated the same second as the oldest ticked one is opened too`() = runTest {
        var asked = 0
        val counting = ListVersionMerge.Opener.With { asked++; dec(it) }
        val v1 = opened(ev(10000, listOf(listOf("p", p(5))), 10), ListVersionMerge.Opener.Later)
        val same = opened(ev(10000, emptyList(), 10, enc(listOf(listOf("word", "z")))), ListVersionMerge.Opener.Later)
        val all = ListVersionMerge.openForMerge(listOf(same, v1), listOf(v1), counting)
        assertEquals(1, asked)
        assertFalse(all.first { it.v.id == same.v.id }.locked)
    }
}
