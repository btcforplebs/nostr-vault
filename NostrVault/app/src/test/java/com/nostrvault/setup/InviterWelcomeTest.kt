package com.nostrvault.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class InviterWelcomeTest {
    private val me = "a".repeat(64)
    private val lena = "b".repeat(64)
    private val t0 = 1_800_000_000_000L

    @Test fun `shows the inviter on the new account's feed for a day`() {
        val e = InviterWelcome.start(me.uppercase(), lena, t0)
        assertEquals(lena, InviterWelcome.inviterFor(e, me, t0))
        assertEquals(lena, InviterWelcome.inviterFor(e, me, t0 + InviterWelcome.LIFETIME_MS - 1))
        assertNull(InviterWelcome.inviterFor(e, me, t0 + InviterWelcome.LIFETIME_MS))
        assertNull(InviterWelcome.inviterFor(e, me, t0 - 1)) // clock moved back
    }

    @Test fun `never on another account, or once waved or closed`() {
        val e = InviterWelcome.start(me, lena, t0)!!
        assertNull(InviterWelcome.inviterFor(e, "c".repeat(64), t0))
        assertNull(InviterWelcome.inviterFor(e.copy(waved = true), me, t0))
        assertNull(InviterWelcome.inviterFor(e.copy(closed = true), me, t0))
    }

    @Test fun `no inviter, yourself or a bad key starts nothing`() {
        assertNull(InviterWelcome.start(me, null, t0))
        assertNull(InviterWelcome.start(me, me, t0))
        assertNull(InviterWelcome.start(me, "npub1x", t0))
    }

    @Test fun `the wave mentions the inviter`() {
        assertEquals("👋 nostr:npub1lena", InviterWelcome.waveContent("npub1lena"))
        assertEquals(listOf(listOf("p", lena)), InviterWelcome.waveTags(lena.uppercase()))
    }
}
