package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** The in-place merge gives what the old full re-sort gave (Messages perf finding 5). */
class DMWithMessageTest {
    private fun msg(id: String, t: Long, fromMe: Boolean = false, text: String = id) =
        DMMessage(id = id, content = text, timestamp = t, senderPubkey = if (fromMe) "me" else "them", isFromMe = fromMe, isNIP04 = false)

    private fun conv(id: String, vararg m: DMMessage, unread: Int = 0) = DMConversation(id = id, messages = m.toList(), unreadCount = unread)

    /** The old code: append, stable sort the chat, stable sort the inbox newest first. */
    private fun oldMerge(list: List<DMConversation>, cp: String, m: DMMessage, addsUnread: Boolean): List<DMConversation> {
        val cur = list.toMutableList()
        val i = cur.indexOfFirst { it.id == cp }
        if (i >= 0) {
            val c = cur[i]
            cur[i] = c.copy(messages = (c.messages + m).sortedBy { it.timestamp }, unreadCount = c.unreadCount + if (addsUnread) 1 else 0)
        } else cur.add(DMConversation(cp, listOf(m), if (addsUnread) 1 else 0))
        cur.sortByDescending { it.lastMessage?.timestamp ?: 0L }
        return cur
    }

    @Test
    fun `matches the old sort for every place a message can land`() {
        val base = listOf(
            conv("a", msg("a1", 10), msg("a2", 50)),
            conv("b", msg("b1", 20), msg("b2", 40)),
            conv("c", msg("c1", 40)),
            conv("d", msg("d1", 5)),
        )
        var n = 0
        for (cp in listOf("a", "b", "c", "d", "new")) for (t in listOf(1L, 5, 10, 20, 39, 40, 41, 50, 60)) {
            val m = msg("x${n++}", t)
            assertEquals("cp=$cp t=$t", oldMerge(base, cp, m, true), base.withMessage(cp, m, alerts = true, onScreen = false))
        }
    }

    @Test
    fun `a known id or a relay echo of my send changes nothing`() {
        val base = listOf(conv("a", msg("a1", 10), msg("mine", 100, fromMe = true, text = "ok")))
        assertSame(base, base.withMessage("a", msg("a1", 10), alerts = true, onScreen = false))
        assertSame(base, base.withMessage("a", msg("real", 105, fromMe = true, text = "ok"), alerts = true, onScreen = false))
    }

    @Test
    fun `unread only when it may alert and the chat is not on screen`() {
        val base = listOf(conv("a", msg("a1", 10), unread = 2))
        assertEquals(3, base.withMessage("a", msg("n1", 11), alerts = true, onScreen = false)[0].unreadCount)
        assertEquals(2, base.withMessage("a", msg("n2", 11), alerts = true, onScreen = true)[0].unreadCount)
        assertEquals(2, base.withMessage("a", msg("n3", 11), alerts = false, onScreen = false)[0].unreadCount)
    }
}
