package com.nostrvault.service

import com.nostrvault.ui.screens.settings.listbackup.ListVersionText
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Recover a List's merge, the gaps from Hal's review of Lazarus 0.7 (Logen 2026-11-03 "fill the gaps"). Port of
 * web-vault/test/list-merge-gaps.test.mjs, fixture for fixture, same numbers; iPhone/Mac twin ListVersionMergeTests.
 *  1 swap clobber            2 bulk cleanup           3 small list / relay list   4 gap between versions
 *  5 10002 marker            6 unpicked in-between    7 re-read changes current   8 step drain 40→20→10→5
 *  9 the wipe flag on a drain step                    10 a removal just before a wipe goes with the wipe
 *  11 NIP-44 always, and the 64 KB cap                12 the mute line counts every type
 *  13 any newer unread version: can't tell            14 a gap bridged by a wipe stays a wipe
 * A version "found only on relays" is one left out of the `vault` set. Stand-in cipher, made-up keys; nothing is
 * published.
 */
class ListMergeGapsTest {
    private val me = "e".repeat(64)
    private var serial = 0

    private fun p(n: Int) = n.toString(16).padStart(64, '0')
    private fun range(a: Int, b: Int) = (a..b).toList()

    private fun ev(kind: Int, tags: List<List<String>>, at: Long, content: String = ""): ListVersion {
        serial++
        return ListVersion("gap%04d".format(serial), me, kind, at, tags, content)
    }

    private fun follows(ns: List<Int>, at: Long) = ev(3, ns.map { listOf("p", p(it)) }, at)

    /** Stand-in for NIP-44 to self: "c:" + base64. Anything else can't be opened (another key's ciphertext). */
    private fun enc(text: String) = "c:" + Base64.getEncoder().encodeToString(text.toByteArray())
    private val open = ListVersionMerge.Opener.With { c ->
        require(c.startsWith("c:")) { "not ours" }
        String(Base64.getDecoder().decode(c.removePrefix("c:")))
    }

    private suspend fun opened(vararg vs: ListVersion) = vs.map { ListVersionMerge.openVersion(it, open) }
    private fun newestFirst(vs: List<ListVersionMerge.Opened>) = vs.sortedByDescending { it.v.createdAt }
    private fun List<ListVersionMerge.Row>.of(n: Int) = first { it.tag[1] == p(n) }
    private fun List<ListVersionMerge.Row>.url(u: String) = first { it.tag[1] == u }
    private fun ids(vararg vs: ListVersionMerge.Opened) = vs.mapTo(mutableSetOf()) { it.v.id }

    private val lost = ListVersionMerge.Status.LOST
    private val removed = ListVersionMerge.Status.REMOVED
    private val back = ListVersionMerge.Status.BACK
    private val unsure = ListVersionMerge.Status.UNSURE

    @Test
    fun `1 swap clobber - a stale list of the same size that swapped the entries out is a wipe`() = runTest {
        val (v1, v2) = opened(follows(range(1, 20), 10), follows(range(101, 120), 20))
        val rows = ListVersionMerge.buildMerge(v2, listOf(v1), listOf(v2, v1))
        for (n in 1..20) {
            assertEquals("P($n) went in the swap", lost, rows.of(n).status)
            assertTrue(rows.of(n).ticked)
        }
    }

    @Test
    fun `2 bulk cleanup - 5 of 20 unfollowed on purpose stays out, more than half reads as a wipe`() = runTest {
        val (a1, a2) = opened(follows(range(1, 20), 10), follows(range(6, 20), 20))
        val out = ListVersionMerge.buildMerge(a2, listOf(a1), listOf(a2, a1))
        for (n in 1..5) assertEquals(removed to false, out.of(n).status to out.of(n).ticked)
        val (b1, b2) = opened(follows(range(1, 20), 10), follows(range(12, 20), 20))
        assertEquals("11 of 20 is more than half", lost, ListVersionMerge.buildMerge(b2, listOf(b1), listOf(b2, b1)).of(1).status)
        val (c1, c2) = opened(follows(range(1, 20), 10), follows(range(11, 20), 20))
        assertEquals("exactly half kept is still an edit", removed, ListVersionMerge.buildMerge(c2, listOf(c1), listOf(c2, c1)).of(1).status)
    }

    @Test
    fun `3 small list and relay lists - everything an old version had goes back ticked`() = runTest {
        val (s1, s2) = opened(follows(listOf(1, 2, 3, 4, 5), 10), follows(listOf(1, 2, 3, 4), 20))
        val small = ListVersionMerge.buildMerge(s2, listOf(s1), listOf(s2, s1))
        // Ticked, yet Review still says when it went (Tron's note 1, Logen 2026-11-03).
        assertEquals(Triple(removed, true, 20L), Triple(small.of(5).status, small.of(5).ticked, small.of(5).at))
        // A DM relay list of 12, one dropped in an edit: still offered back.
        val urls = range(1, 12).map { listOf("relay", "wss://r$it.example") }
        val (r1, r2) = opened(ev(10050, urls, 10), ev(10050, urls.drop(1), 20))
        val r = ListVersionMerge.buildMerge(r2, listOf(r1), listOf(r2, r1)).url("wss://r1.example")
        assertEquals(Triple(removed, true, 20L), Triple(r.status, r.ticked, r.at))
        // Blocked relays across a gap too: relay lists don't wait on the gap rule.
        val (b1, b2, b3) = opened(
            ev(10006, listOf(listOf("relay", "wss://x.example")), 10),
            ev(10006, listOf(listOf("relay", "wss://y.example")), 20),
            ev(10006, listOf(listOf("relay", "wss://y.example")), 30),
        )
        val x = ListVersionMerge.buildMerge(b3, listOf(b1), listOf(b3, b2, b1), ids(b3)).url("wss://x.example")
        assertEquals(Triple(removed, true, 20L), Triple(x.status, x.ticked, x.at))
        val sum = ListVersionMerge.mergeSummary(10006, ListVersionMerge.buildMerge(b3, listOf(b1), listOf(b3, b2, b1), ids(b3)))
        assertEquals("ticked removals aren't counted as left out", 0 to 1, sum.leftOut to sum.added)
    }

    @Test
    fun `4 gap - a step the vault didn't keep both sides of can't be judged, so it stays out`() = runTest {
        // v2 was found only on a relay: the vault never had it, so versions between v1 and v2 may be missing.
        val (v1, v2, v3) = opened(follows(range(1, 20), 10), follows(range(2, 20), 20), follows(range(2, 20), 30))
        val rows = ListVersionMerge.buildMerge(v3, listOf(v1), listOf(v3, v2, v1), ids(v3, v1))
        assertEquals(Triple(unsure, false, 20L), Triple(rows.of(1).status, rows.of(1).ticked, rows.of(1).at))
        val sum = ListVersionMerge.mergeSummary(3, rows)
        assertEquals(1, sum.unsure)
        assertTrue(ListVersionText.leftOutLines(sum).joinToString(" ").contains("1 stays out because the versions in between weren't all kept"))
        // The same versions all from the vault: an ordinary edit, judged.
        assertEquals(removed, ListVersionMerge.buildMerge(v3, listOf(v1), listOf(v3, v2, v1), ids(v3, v2, v1)).of(1).status)
        // Past the vault's newest VAULT_KEEP its versions have holes (only wipes' pins are kept): unsure there too.
        val evs = mutableListOf(follows(range(1, 20), 1))
        for (i in 0..ListVersionMerge.VAULT_KEEP) evs += follows(range(2, 20) + (1000 + i), 10L + i)
        val vs = opened(*evs.toTypedArray())
        val keep = ListVersionMerge.unbroken(vs.map { it.v })
        val old = ListVersionMerge.buildMerge(vs.last(), listOf(vs[0], vs[ListVersionMerge.VAULT_KEEP]), vs, keep)
        assertEquals("dropped between two versions the vault has trimmed between", unsure, old.of(1).status)
        assertEquals("dropped inside the newest 20: judged", removed, old.of(1000 + ListVersionMerge.VAULT_KEEP - 1).status)
    }

    @Test
    fun `5 kind 10002 - the list now's marker wins, an entry not in it keeps the newest picked one's`() = runTest {
        val (old, mid, cur) = opened(
            ev(10002, listOf(listOf("r", "wss://a.example"), listOf("r", "wss://b.example", "write")), 10),
            ev(10002, listOf(listOf("r", "wss://a.example/", "write"), listOf("r", "wss://b.example", "read")), 20),
            ev(10002, listOf(listOf("r", "wss://A.example", "read")), 30),
        )
        val rows = ListVersionMerge.buildMerge(cur, listOf(old, mid), listOf(cur, mid, old))
        assertEquals("a.example spelled three ways is one relay", 2, rows.size)
        assertEquals("not widened to read and write", listOf("r", "wss://A.example", "read"), rows.first { "a.example" in it.key }.tag)
        val b = rows.first { "b.example" in it.key }
        assertEquals("the newest picked form", listOf("r", "wss://b.example", "read"), b.tag)
        assertTrue("a relay list: back ticked", b.ticked)
        // Still not saved from List backups: only Settings › Relays sends a 10002 (Logen 2026-10-31).
        assertTrue(ListMergeSave.refusal(10002, cur.v, true, listOf(listOf("r", "wss://b.example")), emptyList())!!.contains("can't be merged"))
    }

    @Test
    fun `6 unpicked in-between - the newest of all versions holding it decides, picked or not`() = runTest {
        val (v1, v2, v3, cur) = opened(
            follows(range(1, 20), 10), follows(range(1, 25), 20), follows(range(101, 125), 30), follows(range(101, 126), 40),
        )
        val rows = ListVersionMerge.buildMerge(cur, listOf(v1), listOf(cur, v3, v2, v1))
        assertEquals(lost to 30L, rows.of(1).status to rows.of(1).at)
        assertFalse("only the picked versions' entries are offered", rows.any { it.tag[1] == p(21) })
    }

    @Test
    fun `7 re-read changes current - Save refuses, and the rebuilt merge judges again with the new list`() = runTest {
        val (v1, cur1) = opened(follows(range(1, 20), 10), follows(range(1, 20) + 50, 20))
        val before = ListVersionMerge.buildMerge(cur1, listOf(v1), listOf(cur1, v1))
        assertEquals(ListVersionMerge.Status.CURRENT, before.of(50).status)
        // Another app saved the list meanwhile, dropping P(50) in an ordinary edit.
        val cur2ev = follows(range(1, 20), 30)
        val steps = object : ListVersionSave.Steps {
            override fun activeAccount() = me
            override suspend fun newest() = Result.success<NostrEvent?>(NostrEvent(cur2ev.id, me, cur2ev.createdAt, 3, cur2ev.tags, "", "sig"))
            override suspend fun keepUndoCopy(current: NostrEvent) = error("not reached")
            override suspend fun sign(kind: Int, content: String, tags: List<List<String>>, notBefore: Long) = error("not signed")
            override suspend fun store(signed: NostrEvent) = error("not reached")
            override suspend fun send(signed: NostrEvent) = error("not reached")
        }
        val out = ListVersionSave(steps).save(me, 3, cur1.v.id, "merge") { error("not built") }
        assertTrue("the screen reloads on this one", out is ListVersionSave.Outcome.Refused && out.changed)
        val (cur2) = opened(cur2ev)
        val after = ListVersionMerge.buildMerge(cur2, listOf(v1, cur1), listOf(cur2, cur1, v1))
        assertEquals("not current any more: judged as the edit it was", removed to false, after.of(50).status to after.of(50).ticked)
    }

    @Test
    fun `8 step drain 40-20-10-5 - every step's losses are a wipe, though no single step lost over half`() = runTest {
        val vs = opened(follows(range(1, 40), 10), follows(range(1, 20), 20), follows(range(1, 10), 30), follows(range(1, 5), 40))
        val rows = ListVersionMerge.buildMerge(vs[3], listOf(vs[0]), vs)
        for (n in listOf(30, 15, 8)) assertEquals("P($n)", lost to true, rows.of(n).status to rows.of(n).ticked)
        assertEquals(35, ListVersionMerge.mergeSummary(3, rows).added)
    }

    @Test
    fun `9 the wiped-your-list flag sees a drain step, not only a halving next to it`() = runTest {
        val drain = newestFirst(opened(follows(range(1, 40), 10), follows(range(1, 20), 20), follows(range(1, 10), 30)))
        assertEquals("10 wiped 40 (two steps back); 20 kept half", listOf(true, false, false), drain.indices.map { ListVersionMerge.wasWipe(drain, it) })
        val after = newestFirst(opened(follows(range(1, 40), 10), follows(range(1, 10), 20), follows(range(1, 9), 30)))
        assertEquals("9 is an edit after the wipe, not a second one", listOf(false, true, false), after.indices.map { ListVersionMerge.wasWipe(after, it) })
        val swap = newestFirst(opened(follows(range(1, 20), 10), follows(range(101, 120), 20)))
        assertTrue("a same-size swap", ListVersionMerge.wasWipe(swap, 0))
    }

    @Test
    fun `10 a removal one step before a wipe goes with the wipe, ticked to untick in Review`() = runTest {
        val vs = opened(follows(range(1, 21), 10), follows(range(1, 20), 20), follows(range(1, 4) + range(30, 35), 30))
        assertEquals(lost, ListVersionMerge.buildMerge(vs[2], listOf(vs[0]), vs).of(21).status)
        // Past LOOKBACK versions the wipe no longer reaches back to it.
        val evs = mutableListOf(follows(range(1, 21), 1), follows(range(1, 20), 2))
        for (i in 0 until 5) evs += follows(range(1, 20) + (500 + i), 3L + i)
        evs += follows(listOf(1), 20)
        val far = opened(*evs.toTypedArray())
        assertEquals(removed, ListVersionMerge.buildMerge(far.last(), listOf(far[0]), far).of(21).status)
    }

    @Test
    fun `11 NIP-44 always, also over a NIP-04 list, and over 64 KB of private entries is refused before encrypting`() = runTest {
        val base = NostrEvent("b", me, 100, 10000, emptyList(), "abc?iv=def", "sig")
        var asked = 0
        val encrypt: suspend (String, Boolean) -> String? = { text, nip04 -> asked++; if (nip04) "$text?iv=x" else "n44:$text" }
        val decrypt: suspend (String, Boolean) -> String? = { text, nip04 -> if (!nip04 && text.startsWith("n44:")) text.removePrefix("n44:") else null }
        val big = range(1, 1000).map { listOf("p", p(it)) } // 1000 × ~71 bytes
        val refused = ListMergeSave.build(10000, base, emptyList(), big, encrypt, decrypt)
        assertEquals(ListVersionSave.Build.Refuse(ListMergeSave.TOO_BIG), refused)
        assertEquals("nothing sent to the signer", 0, asked)
        val ok = ListMergeSave.build(10000, base, emptyList(), listOf(listOf("p", p(1)), listOf("word", "x")), encrypt, decrypt)
        val content = (ok as ListVersionSave.Build.Ready).content
        assertFalse("not NIP-04", "?iv=" in content)
        assertEquals("n44:[[\"p\",\"${p(1)}\"],[\"word\",\"x\"]]", content)
        // The note shows only when private entries are saved over a NIP-04 list.
        val row = ListVersionMerge.Row("k", listOf("p", p(1)), private = true, status = back, at = 0, ticked = true, from = emptyList())
        assertTrue(ListMergeSave.needsNip44Note(10000, base.content, listOf(row)))
        assertFalse(ListMergeSave.needsNip44Note(10000, "n44:x", listOf(row)))
        assertFalse(ListMergeSave.needsNip44Note(10000, base.content, listOf(row.copy(private = false))))
    }

    @Test
    fun `12 the mute line counts people, words, hashtags and threads`() = runTest {
        val many = range(200, 209).map { listOf("p", p(it)) }
        val (old, cur) = opened(
            ev(10000, many + listOf(listOf("p", p(1)), listOf("p", p(2)), listOf("word", "spam"), listOf("t", "nsfw"), listOf("e", p(9))), 10),
            ev(10000, emptyList(), 20), // a wipe
        )
        val rows = ListVersionMerge.buildMerge(cur, listOf(old), listOf(cur, old))
        val sum = ListVersionMerge.mergeSummary(10000, rows)
        assertEquals(ListVersionMerge.Remutes(people = 12, words = 1, hashtags = 1, threads = 1), sum.remutes)
        assertEquals("This mutes again: 12 people, 1 word, 1 hashtag, 1 thread.", ListVersionText.remuteLine(sum.remutes))
        assertEquals("This mutes again: 1 person, 2 hashtags.", ListVersionText.remuteLine(ListVersionMerge.Remutes(people = 1, hashtags = 2)))
        assertEquals("", ListVersionText.remuteLine(ListVersionMerge.Remutes()))
        assertEquals("only a mute list mutes", 0, ListVersionMerge.mergeSummary(3, rows).remutes.people)
    }

    @Test
    fun `13 strict rule - any newer version with an unread private part makes it can't tell, unticked`() = runTest {
        val unreadBlob = "x:another-key" // not ours: can't be opened
        val mutes = range(1, 20).map { listOf("p", p(it)) }
        // The unread one is two steps on, not the next: the next alone would call it "removed".
        val (m1, m2, m3, m4) = opened(
            ev(10000, mutes, 10), ev(10000, mutes.drop(1), 20), ev(10000, mutes.drop(1), 30, unreadBlob), ev(10000, mutes.drop(1), 40),
        )
        assertTrue(m3.unread)
        val r = ListVersionMerge.buildMerge(m4, listOf(m1), listOf(m4, m3, m2, m1)).of(1)
        assertEquals(unsure to false, r.status to r.ticked)
        // Opened, the same step is judged: an ordinary edit.
        val m3read = ListVersionMerge.openVersion(m3.v.copy(content = enc("[]")), open)
        assertEquals(removed, ListVersionMerge.buildMerge(m4, listOf(m1), listOf(m4, m3read, m2, m1)).of(1).status)
    }

    @Test
    fun `14 gap bridged by a wipe - the step to a relay-only version that wiped H is judged a wipe`() = runTest {
        val (v1, v2, v3) = opened(follows(range(1, 20), 10), follows(listOf(1, 2), 20), follows(listOf(1, 2), 30))
        val r = ListVersionMerge.buildMerge(v3, listOf(v1), listOf(v3, v2, v1), ids(v3, v1)).of(5)
        assertEquals(Triple(lost, true, 20L), Triple(r.status, r.ticked, r.at))
    }
}
