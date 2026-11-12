package com.nostrvault.service

import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.service.VaultHandoffDecision.PHONE_SENDS
import com.nostrvault.service.VaultHandoffDecision.VAULT_SENDS
import kotlinx.coroutines.runBlocking
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Publish for me (sync pick 1): exactly one device blasts each note. The vault only when it answers OK true with no
 * message on the publish connection (haven-go mesh_publish.go); every other answer, or none, means the phone sends.
 * Twin of Apple's VaultHandoffDecision tests.
 */
class VaultHandoffDecisionTest {
    private val mac = "npub15ltk3g7wjmt0sjqk78cjv4mtttmy8ffyy9g7hg7spxwdz28wr2wszsrurl"
    private val other = "npub12fuf7setehcxg6dvdl2muj5dmk9c7kjmhcvexd0ndtskanfzjpns76048p"
    private val ws = "ws://127.0.0.1:41234/0123456789abcdef"
    private val id = "ab".repeat(32)

    private val server = MockWebServer()

    @After fun tearDown() {
        runCatching { server.shutdown() }
    }

    // The decision.

    @Test fun okTrueFromTheVaultMeansTheVaultSends() {
        assertEquals(VAULT_SENDS, VaultHandoffDecision.decide(connected = true, sawPublishNotice = true, accepted = true, message = "", timedOut = false))
    }

    @Test fun everyRefusalMeansThePhoneSends() {
        for (m in listOf("duplicate: the vault already holds this note", "blocked: too old", "restricted: owner only", "error: x")) {
            assertEquals(m, PHONE_SENDS, VaultHandoffDecision.decide(connected = true, sawPublishNotice = true, accepted = false, message = m, timedOut = false))
        }
        // An OK true that says it was already there is not "stored and queued its blast".
        assertEquals(PHONE_SENDS, VaultHandoffDecision.decide(connected = true, sawPublishNotice = true, accepted = true, message = "duplicate: already have it", timedOut = false))
    }

    @Test fun noAnswerOrNoConnectionMeansThePhoneSends() {
        assertEquals(PHONE_SENDS, VaultHandoffDecision.decide(connected = true, sawPublishNotice = true, accepted = null, message = null, timedOut = true))
        assertEquals(PHONE_SENDS, VaultHandoffDecision.decide(connected = false, sawPublishNotice = false, accepted = null, message = null, timedOut = false))
        // A late OK true after the hold ran out: the phone already sent it.
        assertEquals(PHONE_SENDS, VaultHandoffDecision.decide(connected = true, sawPublishNotice = true, accepted = true, message = "", timedOut = true))
    }

    @Test fun okTrueWithoutThePublishNoticeMeansThePhoneSends() {
        // An older vault, or one that has not paired this phone, answers a plain OK true and never sends the note.
        assertEquals(PHONE_SENDS, VaultHandoffDecision.decide(connected = true, sawPublishNotice = false, accepted = true, message = "", timedOut = false))
    }

    @Test fun onlyTheExactNoticeCounts() {
        assertTrue(VaultHandoffDecision.isPublishNotice("""["NOTICE","publish-for-me: on"]"""))
        assertFalse(VaultHandoffDecision.isPublishNotice("""["NOTICE","publish-for-me: off"]"""))
        assertFalse(VaultHandoffDecision.isPublishNotice("""["NOTICE","publish-for-me: on "]"""))
        assertFalse(VaultHandoffDecision.isPublishNotice("""["OK","$id",true,""]"""))
        assertFalse(VaultHandoffDecision.isPublishNotice("not json"))
    }

    @Test fun onlyTheOkForThisNoteCounts() {
        assertEquals(true to "", VaultHandoffDecision.okAnswer("""["OK","$id",true,""]""", id))
        assertEquals(false to "duplicate: x", VaultHandoffDecision.okAnswer("""["OK","$id",false,"duplicate: x"]""", id))
        assertNull(VaultHandoffDecision.okAnswer("""["OK","${"cd".repeat(32)}",true,""]""", id))
        assertNull(VaultHandoffDecision.okAnswer("""["NOTICE","hi"]""", id))
        assertNull(VaultHandoffDecision.okAnswer("not json", id))
    }

    // The gate.

    @Test fun onlyTheDialedOwnersMacIsTheVault() {
        val config = HavenConfig(macRelayURL = "fipsmesh://$mac/", fipsMeshEnabled = true)
        val dialed = RelayConfiguration.MacMeshRelay(mac, ws)
        assertEquals(dialed, VaultPublishHandoff.target(config, dialed))
        assertTrue(VaultPublishHandoff.isEnabled(config, dialed))
        // Not dialed, another Mac, mesh off, a Mac with a URL: no hold at all.
        assertFalse(VaultPublishHandoff.isEnabled(config, null))
        assertFalse(VaultPublishHandoff.isEnabled(config, RelayConfiguration.MacMeshRelay(other, ws)))
        assertFalse(VaultPublishHandoff.isEnabled(config.copy(fipsMeshEnabled = false), dialed))
        assertFalse(VaultPublishHandoff.isEnabled(HavenConfig(macRelayURL = "mac.example.com", fipsMeshEnabled = true), dialed))
        assertFalse(VaultPublishHandoff.isEnabled(HavenConfig(), dialed))
    }

    // The handoff over a socket.

    /** A vault: [notice] is its first frame (a publish-for-me vault says it; an older one does not). */
    private class FakeVault(val answer: String?, val notice: String? = null) : WebSocketListener() {
        val received = LinkedBlockingQueue<String>()
        override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
            notice?.let { webSocket.send(it) }
        }
        override fun onMessage(webSocket: WebSocket, text: String) {
            received.add(text)
            answer?.let { webSocket.send(it) }
        }
    }

    private fun vaultUrl() = server.url("/").toString().replaceFirst("http://", "ws://")
    private val eventJson = """{"id":"$id","kind":1}"""
    private val on = """["NOTICE","publish-for-me: on"]"""

    @Test fun anOlderVaultsOkTrueWithoutTheNoticeMeansThePhoneSends() = runBlocking {
        server.enqueue(MockResponse().withWebSocketUpgrade(FakeVault("""["OK","$id",true,""]""")))
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dA==", holdMs = 2_000))
    }

    @Test fun anyOtherFirstFrameMeansThePhoneSendsAtOnce() = runBlocking {
        val vault = FakeVault("""["OK","$id",true,""]""", notice = """["NOTICE","hello"]""")
        server.enqueue(MockResponse().withWebSocketUpgrade(vault))
        val started = System.nanoTime()
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dA==", holdMs = 10_000))
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 5_000)
        // The note never went to a vault that did not say it sends.
        assertNull(vault.received.poll(300, TimeUnit.MILLISECONDS))
    }

    @Test fun anUnpairedDevicesForbiddenUpgradeFallsBackAtOnce() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(403))
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dA==", holdMs = 10_000))
    }

    @Test fun theNoteGoesWithTheDeviceTokenAndAnOkTrueKeepsThePhoneQuiet() = runBlocking {
        val vault = FakeVault("""["OK","$id",true,""]""", notice = on)
        server.enqueue(MockResponse().withWebSocketUpgrade(vault))
        val decision = VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dG9rZW4=")
        assertEquals(VAULT_SENDS, decision)
        val upgrade = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("Nostr dG9rZW4=", upgrade.getHeader("Authorization"))
        assertFalse(upgrade.path!!.contains("pulled"))
        assertEquals("""["EVENT",$eventJson]""", vault.received.poll(1, TimeUnit.SECONDS))
    }

    @Test fun aDuplicateMeansThePhoneSends() = runBlocking {
        server.enqueue(MockResponse().withWebSocketUpgrade(FakeVault("""["OK","$id",false,"duplicate: held"]""", notice = on)))
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dA=="))
    }

    @Test fun aRefusedUpgradeFallsBackAtOnce() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))
        val started = System.nanoTime()
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dA==", holdMs = 10_000))
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 5_000)
    }

    @Test fun noMeshKeyNeverDials() = runBlocking {
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = null))
        assertEquals(0, server.requestCount)
    }

    @Test fun silenceForTheHoldMeansThePhoneSends() = runBlocking {
        server.enqueue(MockResponse().withWebSocketUpgrade(FakeVault(null, notice = on)))
        assertEquals(PHONE_SENDS, VaultPublishHandoff.handOff(vaultUrl(), id, eventJson, token = "dA==", holdMs = 500))
    }

    @Test fun theConfirmedNoteIsStoredOnThePhoneAsSecondHand() = runBlocking {
        val local = FakeVault("""["OK","$id",true,""]""")
        server.enqueue(MockResponse().withWebSocketUpgrade(local))
        assertTrue(VaultPublishHandoff.storeLocally(vaultUrl(), id, eventJson))
        val upgrade = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("/?pulled=1", upgrade.path)
        assertNull(upgrade.getHeader("Authorization"))
        assertEquals("""["EVENT",$eventJson]""", local.received.poll(1, TimeUnit.SECONDS))
    }
}
