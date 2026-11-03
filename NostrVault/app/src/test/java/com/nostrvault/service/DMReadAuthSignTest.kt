package com.nostrvault.service

import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The DM read AUTH runs on foreground and pull-to-refresh with nobody asking,
 * so it may only ever sign silently: Amber's approval screen must not open.
 */
class DMReadAuthSignTest {
    private val me = "aa".repeat(32)

    private fun nostr(signed: NostrEvent?): NostrService = mockk<NostrService>(relaxed = true).also {
        every { it.activeHexPubkey } returns me
        coEvery { it.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } returns signed
    }

    @Test fun `the read AUTH is signed silentOnly, never with the approval screen`() = runTest {
        val event = NostrEvent("id", me, 0, 22242, emptyList(), "", "sig")
        val n = nostr(event)
        assertEquals(event, signDmReadAuth(n, "wss://relay.example", "c1", me))
        coVerify(exactly = 1) {
            n.signEventAsync(kind = 22242, content = any(), tags = any(), password = any(), forceOwner = any(), lockedTo = any(), silentOnly = true, notBefore = any())
        }
        coVerify(exactly = 0) {
            n.signEventAsync(any(), any(), any(), any(), any(), any(), silentOnly = false, notBefore = any())
        }
    }

    @Test fun `a signer that cannot sign silently gives null, no fallback ask`() = runTest {
        val n = nostr(null)
        coEvery { n.signEventAsync(any(), any(), any(), any(), any(), any(), true, any()) } throws IllegalStateException("needs approval")
        assertNull(signDmReadAuth(n, "wss://relay.example", "c1", me))
        coVerify(exactly = 0) {
            n.signEventAsync(any(), any(), any(), any(), any(), any(), silentOnly = false, notBefore = any())
        }
    }

    @Test fun `a switched account is not proven`() = runTest {
        val n = nostr(NostrEvent("id", me, 0, 22242, emptyList(), "", "sig"))
        assertNull(signDmReadAuth(n, "wss://relay.example", "c1", "bb".repeat(32)))
        coVerify(exactly = 0) { n.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) }
    }
}
