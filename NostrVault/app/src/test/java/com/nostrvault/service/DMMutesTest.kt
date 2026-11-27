package com.nostrvault.service

import com.nostrvault.data.model.DMMutes
import com.nostrvault.data.model.MuteRules
import com.nostrvault.data.model.MutedThings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A muted word in a DM you received hides the whole conversation row (Logen 2026-11-27). */
class DMMutesTest {
    private val rules = MuteRules(MutedThings(words = listOf("crypto")))
    private fun msg(id: String, content: String, mine: Boolean = false) =
        DMMessage(id = id, content = content, timestamp = id.length.toLong(), senderPubkey = if (mine) "me" else "them", isFromMe = mine)
    private fun conv(id: String, vararg m: DMMessage) = DMConversation(id = id, messages = m.toList())

    @Test fun `a received message with a muted word hides the conversation`() {
        assertTrue(conv("a", msg("1", "hi"), msg("2", "Buy CRYPTO now!")).isMuted(rules))
    }

    @Test fun `your own messages and partial words never hide it`() {
        assertFalse(conv("a", msg("1", "I don't do crypto", mine = true)).isMuted(rules))
        assertFalse(conv("b", msg("1", "cryptography class")).isMuted(rules))
        assertFalse(conv("c", msg("1", "crypto")).isMuted(MuteRules.NONE))
    }

    @Test fun `split keeps order on both sides`() {
        val a = conv("a", msg("1", "hello"))
        val b = conv("b", msg("1", "crypto"))
        val c = conv("c", msg("1", "lunch?"))
        assertEquals(listOf(a, c) to listOf(b), DMMutes.split(listOf(a, b, c)) { it.isMuted(rules) })
    }
}
