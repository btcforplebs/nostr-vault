package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The vault session's NIP-42 order (twin of iOS VaultSessionCoreTests, #1739). */
class VaultSessionCoreTest {
    private fun arr(text: String): JsonArray = Json.parseToJsonElement(text).jsonArray
    private fun VaultSessionCore.recv(text: String) = arr(text).let { received(it[0].jsonPrimitive.content, it) }
    private fun List<VaultSessionCore.Effect>.signs() = count { it is VaultSessionCore.Effect.SignAuth }
    private fun List<VaultSessionCore.Effect>.sends() = filterIsInstance<VaultSessionCore.Effect.Send>().map { it.frame }
    private fun List<VaultSessionCore.Effect>.finishes() = filterIsInstance<VaultSessionCore.Effect.Finish>()

    /** A logged-in session: connected, challenged, signed, OK'd. */
    private fun authed(): Pair<VaultSessionCore, MutableList<VaultSessionCore.Effect>> {
        val core = VaultSessionCore()
        val all = mutableListOf<VaultSessionCore.Effect>()
        all += core.submit("s1", VaultSessionCore.Kind.REQ, "[\"REQ\",\"s1\",{}]").second
        all += core.connected()
        all += core.recv("[\"AUTH\",\"c1\"]")
        all += core.authSigned("auth1", "[\"AUTH\",{\"id\":\"auth1\"}]")
        all += core.recv("[\"OK\",\"auth1\",true,\"\"]")
        all += core.recv("[\"EOSE\",\"s1\"]")
        return core to all
    }

    @Test
    fun `many requests on one socket sign one AUTH`() {
        val (core, all) = authed()
        repeat(10) { i ->
            all += core.submit("q$i", VaultSessionCore.Kind.REQ, "[\"REQ\",\"q$i\",{}]").second
            all += core.recv("[\"EOSE\",\"q$i\"]")
            all += core.submit("e$i", VaultSessionCore.Kind.EVENT, "[\"EVENT\",{\"id\":\"e$i\"}]").second
            all += core.recv("[\"OK\",\"e$i\",true,\"\"]")
        }
        assertEquals(1, all.signs())
        assertEquals(21, all.finishes().size)
        // A second challenge on a logged-in socket is not answered.
        assertEquals(0, core.recv("[\"AUTH\",\"c2\"]").signs())
    }

    @Test
    fun `a drop logs in again once on the next connection`() {
        val (core, all) = authed()
        all += core.disconnected()
        all += core.submit("q", VaultSessionCore.Kind.REQ, "[\"REQ\",\"q\",{}]").second
        assertTrue(all.last() is VaultSessionCore.Effect.Connect)
        all += core.connected()
        all += core.recv("[\"AUTH\",\"c2\"]")
        assertEquals(2, all.signs())
    }

    @Test
    fun `requests wait for the AUTH's OK, then go`() {
        val core = VaultSessionCore()
        core.submit("s", VaultSessionCore.Kind.REQ, "[\"REQ\",\"s\",{}]")
        assertEquals(listOf("[\"REQ\",\"s\",{}]"), core.connected().sends())
        core.recv("[\"CLOSED\",\"s\",\"auth-required: log in\"]")
        core.recv("[\"AUTH\",\"c\"]")
        assertEquals(listOf("[\"AUTH\",{}]"), core.authSigned("a", "[\"AUTH\",{}]").sends())
        assertEquals("held during the login", 0, core.submit("t", VaultSessionCore.Kind.REQ, "[\"REQ\",\"t\",{}]").second.sends().size)
        assertEquals(listOf("[\"REQ\",\"s\",{}]", "[\"REQ\",\"t\",{}]"), core.recv("[\"OK\",\"a\",true,\"\"]").sends())
    }

    @Test
    fun `auth-required after the login gets one retry, then the socket closes`() {
        val (core, _) = authed()
        core.submit("e", VaultSessionCore.Kind.EVENT, "[\"EVENT\",{\"id\":\"e\"}]")
        assertEquals(listOf("[\"EVENT\",{\"id\":\"e\"}]"), core.recv("[\"OK\",\"e\",false,\"auth-required: x\"]").sends())
        val again = core.recv("[\"OK\",\"e\",false,\"auth-required: x\"]")
        assertTrue(again.first() is VaultSessionCore.Effect.Disconnect)
        assertEquals(VaultSessionCore.Outcome.Failed, again.finishes().single().outcome)
    }

    @Test
    fun `a refused login closes the socket and fails what waits`() {
        val core = VaultSessionCore()
        core.submit("s", VaultSessionCore.Kind.REQ, "[\"REQ\",\"s\",{}]")
        core.connected()
        core.recv("[\"AUTH\",\"c\"]")
        core.authSigned("a", "[\"AUTH\",{}]")
        val out = core.recv("[\"OK\",\"a\",false,\"blocked\"]")
        assertTrue(out.first() is VaultSessionCore.Effect.Disconnect)
        assertEquals(VaultSessionCore.Link.DOWN, core.link)
    }

    @Test
    fun `no signer closes the socket rather than waiting`() {
        val core = VaultSessionCore()
        core.submit("s", VaultSessionCore.Kind.REQ, "[\"REQ\",\"s\",{}]")
        core.connected()
        core.recv("[\"AUTH\",\"c\"]")
        val out = core.authUnavailable()
        assertTrue(out.first() is VaultSessionCore.Effect.Disconnect)
        assertEquals(VaultSessionCore.Outcome.Failed, out.finishes().single().outcome)
    }

    @Test
    fun `an old timer can't end a newer submission, and a silent socket is closed`() {
        val (core, _) = authed()
        val first = core.submit("e", VaultSessionCore.Kind.EVENT, "[\"EVENT\",{\"id\":\"e\"}]").first
        val second = core.submit("e", VaultSessionCore.Kind.EVENT, "[\"EVENT\",{\"id\":\"e\"}]").first
        assertEquals(emptyList<VaultSessionCore.Effect>(), core.timedOut("e", first))
        // Nothing heard since it was sent: dead socket.
        assertTrue(core.timedOut("e", second).first() is VaultSessionCore.Effect.Disconnect)
    }

    @Test
    fun `EOSE closes the subscription on the vault and returns its events`() {
        val (core, _) = authed()
        core.submit("q", VaultSessionCore.Kind.REQ, "[\"REQ\",\"q\",{}]")
        core.recv("[\"EVENT\",\"q\",{\"id\":\"x\"}]")
        val out = core.recv("[\"EOSE\",\"q\"]")
        assertEquals(listOf("[\"CLOSE\",\"q\"]"), out.sends())
        val events = (out.finishes().single().outcome as VaultSessionCore.Outcome.Events).events
        assertEquals("x", events.single()["id"]!!.jsonPrimitive.content)
    }
}
