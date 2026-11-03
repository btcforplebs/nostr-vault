package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * NIP-42 on the external DM read (port of iOS DMReadAuthTests, #1506): a relay
 * that closes the wrap REQ with "auth-required" gets one AUTH, then the REQ
 * again. Never a loop.
 */
class DMReadAuthTest {
    private val req = """["REQ","dm-ext-a-17",{"kinds":[1059]}]"""
    private fun f(s: String): JsonArray = Json.parseToJsonElement(s).jsonArray
    private val closedAuth = f("""["CLOSED","dm-ext-a-17","auth-required: sign in"]""")

    private fun reading(): DMReadAuth = DMReadAuth(mayAuth = true).also { it.sent("dm-ext-a-17", req) }

    @Before fun reset() = DMReadAuth.resetForTests()

    @Test fun `challenge then closed signs, then resends on OK`() {
        val auth = reading()
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["AUTH","c1"]""")))
        assertEquals(DMReadAuth.Step.Sign("c1"), auth.receive(closedAuth))
        assertTrue(auth.isAuthenticating)
        auth.authSent("auth1")
        assertEquals(DMReadAuth.Step.Resend(listOf(req)), auth.receive(f("""["OK","auth1",true,""]""")))
        assertFalse(auth.isAuthenticating)
    }

    @Test fun `a CLOSED before the challenge waits for it`() {
        val auth = reading()
        assertFalse(auth.isAwaitingChallenge)
        assertEquals(DMReadAuth.Step.None, auth.receive(closedAuth))
        // The catch-up must not finish here: its one v2 pass would go without AUTH.
        assertTrue(auth.isAwaitingChallenge)
        assertFalse(auth.isAuthenticating)
        assertEquals(DMReadAuth.Step.Sign("c2"), auth.receive(f("""["AUTH","c2"]""")))
        assertFalse(auth.isAwaitingChallenge)
    }

    @Test fun `a relay we won't AUTH to is never waited on or signed for`() {
        val auth = DMReadAuth(mayAuth = false).also { it.sent("dm-ext-a-17", req) }
        auth.receive(f("""["AUTH","c1"]"""))
        assertEquals(DMReadAuth.Step.None, auth.receive(closedAuth))
        assertFalse(auth.isAwaitingChallenge)
    }

    /** A relay handing out a fresh challenge with every refusal gets one signature per connection (web #879). */
    @Test fun `one signature per connection`() {
        val auth = reading()
        auth.sent("dm-ext-a-04in", "r2")
        auth.receive(f("""["AUTH","c1"]"""))
        assertEquals(DMReadAuth.Step.Sign("c1"), auth.receive(closedAuth))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["AUTH","c2"]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["CLOSED","dm-ext-a-04in","auth-required: x"]""")))
        auth.authSent("a")
        assertEquals(DMReadAuth.Step.Resend(listOf(req, "r2")), auth.receive(f("""["OK","a",true,""]""")))
    }

    @Test fun `closed again after AUTH gives up`() {
        val auth = reading()
        auth.receive(f("""["AUTH","c1"]"""))
        auth.receive(closedAuth)
        auth.authSent("a")
        auth.receive(f("""["OK","a",true,""]"""))
        assertTrue(auth.receive(closedAuth) is DMReadAuth.Step.GiveUp)
        assertEquals(DMReadAuth.Step.None, auth.receive(closedAuth))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["AUTH","c9"]""")))
    }

    @Test fun `a refused AUTH gives up and never signs again`() {
        val auth = reading()
        auth.receive(f("""["AUTH","c1"]"""))
        auth.receive(closedAuth)
        auth.authSent("a")
        assertEquals(DMReadAuth.Step.GiveUp("AUTH refused: restricted"), auth.receive(f("""["OK","a",false,"restricted"]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["AUTH","c2"]""")))
    }

    @Test fun `the signer declining gives up`() {
        val auth = reading()
        auth.receive(f("""["AUTH","c1"]"""))
        auth.receive(closedAuth)
        assertEquals(DMReadAuth.Step.GiveUp("not signed"), auth.signFailed())
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["AUTH","c2"]""")))
    }

    @Test fun `other closes and strange frames are ignored`() {
        val auth = reading()
        auth.receive(f("""["AUTH","c1"]"""))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["CLOSED","dm-ext-a-17","rate-limited: slow"]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["CLOSED","someone-else","auth-required: x"]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["CLOSED"]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["OK","unrelated",true]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""["AUTH"]""")))
        assertEquals(DMReadAuth.Step.None, auth.receive(f("""[]""")))
    }

    /** A relay given up on is read without AUTH for the rest of the session, per account. */
    @Test fun `a given-up relay is not asked again this session`() {
        val me = "a".repeat(64)
        val other = "b".repeat(64)
        assertTrue(DMReadAuth.mayAuth(me, "wss://relay.damus.io"))
        DMReadAuth.giveUp(me, "wss://relay.damus.io/")
        assertFalse(DMReadAuth.mayAuth(me, "WSS://Relay.Damus.io"))
        assertTrue(DMReadAuth.mayAuth(other, "wss://relay.damus.io"))
        assertFalse(DMReadAuth.mayAuth("", "wss://nostr.wine"))
    }

    @Test fun `the connection is kept open once while an AUTH is under way`() {
        var now = 1_000L
        val link = DMReadAuthLink("wss://nostr.wine", "a".repeat(64), mayAuth = true) { now }
        link.sent("dm-ext-a-17", req)
        assertFalse("nothing asked for AUTH yet", link.mayExtend())
        link.receive(f("""["AUTH","c1"]"""))
        link.receive(closedAuth)
        assertTrue(link.mayExtend())
        assertFalse("only once", link.mayExtend())
        link.authSent("a")
        link.receive(f("""["OK","a",true,""]"""))
        link.markResent()
        assertTrue(link.resentRecently)
        now += 8_001
        assertFalse(link.resentRecently)
    }

    // Fetch order

    @Test fun `DM inbox relays come before read relays under the cap`() {
        val read = (1..14).map { "wss://feed$it.example" }
        val relays = DMReadAuth.fetchRelays(listOf(listOf("wss://inbox.example"), listOf("wss://relay.damus.io", "wss://nostr.wine/"), read), cap = 15)
        assertEquals(listOf("wss://inbox.example", "wss://relay.damus.io", "wss://nostr.wine/"), relays.take(3))
        assertEquals(15, relays.size)
    }

    @Test fun `fetch relays drop duplicates, blanks and loopback`() {
        val relays = DMReadAuth.fetchRelays(listOf(listOf("wss://Relay.Damus.io/"), listOf("wss://relay.damus.io", " ", "ws://127.0.0.1:3355/inbox", "ws://localhost:4869")), cap = 15)
        assertEquals(listOf("wss://Relay.Damus.io/"), relays)
    }
}
