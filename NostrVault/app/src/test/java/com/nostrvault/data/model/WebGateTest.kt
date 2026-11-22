package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Android twin of iOS `WebGate` (phase 1.5): the web question, the ration, the hop past the web. */
class WebGateTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')
    private val friend = pk('b') // in the web
    private val near = pk('c') // one hop out
    private val stranger = pk('d')
    private val leaked = pk('e') // in the web, but its nsec is public
    private val web = WebGate.Web(own = setOf(me), web = setOf(friend, leaked), loose = setOf(near))
    private fun judge(who: String, reach: WebGate.Reach = WebGate.Reach.WEB, always: Set<String> = emptySet()) =
        WebGate.judge(who, web, reach, always, isPublic = { it == leaked })

    @Test fun `the rule, first match wins, as iOS`() {
        val (inside, loose, outside) = Triple(WebGate.Verdict.INSIDE, WebGate.Verdict.LOOSE, WebGate.Verdict.OUTSIDE)
        assertEquals(inside, judge(me))
        assertEquals(inside, judge(stranger, always = setOf(stranger.uppercase())))
        assertEquals(inside, judge(friend))
        assertEquals(inside, judge(friend.uppercase()))
        assertEquals(outside, judge(leaked))
        assertEquals(inside, judge(leaked, WebGate.Reach.EVERYONE))
        assertEquals(outside, judge(near))
        assertEquals(loose, judge(near, WebGate.Reach.WEB_AND_LOOSE))
        assertEquals(outside, judge(stranger, WebGate.Reach.WEB_AND_LOOSE))
        assertEquals(inside, judge(stranger, WebGate.Reach.EVERYONE))
        assertEquals(outside, judge("", WebGate.Reach.EVERYONE))
    }

    @Test fun `someone in the web is never one hop out`() {
        val w = WebGate.Web(own = emptySet(), web = setOf(friend), loose = setOf(friend, near))
        assertEquals(setOf(near), w.loose)
        assertEquals(WebGate.Verdict.INSIDE, WebGate.judge(friend, w, WebGate.Reach.WEB_AND_LOOSE, isPublic = { false }))
    }

    @Test fun `the saved word stays webAndHop3, as iOS saves it`() {
        assertEquals("webAndHop3", WebGate.Reach.WEB_AND_LOOSE.stored)
        assertEquals(WebGate.Reach.WEB_AND_LOOSE, WebGate.Reach.fromStored("webAndHop3"))
        assertEquals(WebGate.Reach.WEB, WebGate.Reach.fromStored("web"))
        assertNull(WebGate.Reach.fromStored("webAndLoose"))
        assertNull(WebGate.Reach.fromStored(null))
    }

    private data class Row(val author: String, val v: WebGate.Verdict, val reply: Boolean = false)

    private fun cap(rows: List<Row>) = WebGate.capLoose(rows, { it.v }, { it.author }, { it.reply })

    @Test fun `one hop out is rationed - top-level, one per author, a fifth of the rest or 10`() {
        val inside = List(60) { Row("in$it", WebGate.Verdict.INSIDE) }
        val loose = List(20) { Row("out$it", WebGate.Verdict.LOOSE) }
        // 60 others: max(10, 12) = 12 of the 20.
        val shown = cap(inside + loose)
        assertEquals(60, shown.count { it.v == WebGate.Verdict.INSIDE })
        assertEquals(loose.take(12), shown.filter { it.v == WebGate.Verdict.LOOSE })
        // A feed of only hop-past rows still shows 10.
        assertEquals(10, cap(loose).size)
        // A reply from there goes; a second post by the same author goes.
        val mixed = listOf(Row("x", WebGate.Verdict.LOOSE, reply = true), Row("y", WebGate.Verdict.LOOSE), Row("Y", WebGate.Verdict.LOOSE))
        assertEquals(listOf(Row("y", WebGate.Verdict.LOOSE)), cap(mixed))
        // Order and every other verdict are kept.
        val order = listOf(Row("a", WebGate.Verdict.OUTSIDE), Row("b", WebGate.Verdict.LOOSE), Row("c", WebGate.Verdict.INSIDE))
        assertEquals(order, cap(order))
    }

    private val f1 = pk('1'); private val f2 = pk('2'); private val f3 = pk('3')
    private val vouched3 = pk('7'); private val vouched1 = pk('8'); private val pooledOnly = pk('9')

    private fun loose(follows: Set<String>, counts: Map<String, Int>?, depth: Int? = 3, min: Int = 3, saved: Set<String> = setOf(me, f1, f2, f3, vouched3, vouched1, pooledOnly)) =
        WebGate.loose(saved, follows, counts, depth, setOf(me), min)

    @Test fun `one hop out is the vouched-for under the bar, as iOS layers`() {
        val follows = setOf(f1, f2, f3)
        val counts = mapOf(vouched3 to 3, vouched1 to 1, f1 to 2)
        assertEquals(setOf(vouched1), loose(follows, counts))
        // Depth 2, or no links file: the saved web past the follows.
        assertEquals(setOf(vouched3, vouched1, pooledOnly), loose(follows, null))
        assertEquals(setOf(vouched3, vouched1, pooledOnly), loose(follows, counts, depth = 2))
    }

    @Test fun `it fails closed - no graph, no follow list, nobody`() {
        assertEquals(emptySet<String>(), loose(emptySet(), mapOf(vouched1 to 1)))
        assertEquals(emptySet<String>(), loose(setOf(f1), mapOf(vouched1 to 1), saved = emptySet()))
    }

    @Test fun `a new account's widened web leaves the rest one hop out`() {
        val follows = setOf(f1, f2) // under the bar of 3
        val counts = (0 until WebGate.NEW_ACCOUNT_WEB_CAP + 2).associate { "%064x".format(it + 100) to 1 } + (vouched3 to 2)
        val out = loose(follows, counts, saved = counts.keys + follows + me)
        // vouched3 ranks first (2 vouches), so it is in the widened web; two of the ones are past the cap.
        assertEquals(3, (counts.size - WebGate.NEW_ACCOUNT_WEB_CAP))
        assertEquals(3, out.size)
        assertEquals(false, vouched3 in out)
    }

    @Test fun `vouch counts read the relay's links file`() {
        val text = "{\"timestamp\":1,\"follows\":[\"$f1\",\"$f2\",\"$pooledOnly\"],\"links\":{\"$vouched3\":[0,1,1,2],\"$vouched1\":[2],\"x\":[]}}"
        assertEquals(mapOf(vouched3 to 2), AccountWeb.vouchCounts(text.reader(), setOf(f1, f2)))
        assertNull(AccountWeb.vouchCounts("{\"links\":{},\"follows\":[]}".reader(), setOf(f1)))
        assertNull(AccountWeb.vouchCounts("not json".reader(), setOf(f1)))
        // vouched is the same counts over the bar.
        assertEquals(setOf(vouched3), AccountWeb.vouched(text.reader(), setOf(f1, f2), 2))
        assertEquals(emptySet<String>(), AccountWeb.vouched(text.reader(), setOf(f1, f2), 3))
    }
}
