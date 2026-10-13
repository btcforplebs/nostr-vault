package com.nostrvault.service

import com.nostrvault.relay.AccountBunkerConfig
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #229 parity: switching back to an account reuses its live signer session
 * with no round trip; only an unanswered request plus a failed ping drops it;
 * re-pairing or removing a bunker closes its old session.
 */
class NIP46SessionReuseTest {
    private val ownerHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val ownerSigner = "1".repeat(64)
    private val otherSigner = "2".repeat(64)

    private class FakeBridge(
        val sessions: MutableMap<String, String> = mutableMapOf(),
        var pingResult: Int = 0,
        val connectAnswersAs: String? = null,
        val backgroundAnswersAs: String? = null,
    ) : NIP46Service.Bridge {
        val dropped = mutableListOf<String>()
        var connects = 0
        var backgroundConnects = 0
        var pings = 0
        override fun connect(clientSecretKey: String, bunkerUrl: String): String? {
            connects++
            return connectAnswersAs
        }
        override fun connectBackground(clientSecretKey: String, bunkerUrl: String): String? {
            backgroundConnects++
            return backgroundAnswersAs
        }
        override fun activate(signerPubkey: String): String? = sessions[signerPubkey]
        override fun drop(signerPubkey: String) {
            dropped += signerPubkey
            sessions.remove(signerPubkey)
        }
        override fun ping(): Int {
            pings++
            return pingResult
        }
        override fun signWith(signerPubkey: String, eventJson: String): String? = null
    }

    private fun cfg(signer: String, stored: String = signer) =
        AccountBunkerConfig(bunkerURI = "bunker://$signer?relay=wss://r", signerPubkey = stored)

    @After fun reset() { NIP46Service.disconnectForTest() }

    @Test fun switchBackReusesTheLiveSessionWithoutPinging() = runBlocking {
        // A sleeping signer app misses pings; that must not cost a re-login.
        val fake = FakeBridge(sessions = mutableMapOf(otherSigner to otherHex), pingResult = 1)
        NIP46Service.bridge = fake
        assertEquals(otherHex, NIP46Service.connectForAccount(cfg(otherSigner), expectedPubkey = otherHex))
        assertTrue(NIP46Service.isConnected.value)
        assertEquals(0, fake.pings)
        assertEquals(0, fake.connects)
        assertTrue(fake.dropped.isEmpty())
    }

    /**
     * After a restart with another account active, the owner's bunker is
     * opened in the background for the owner's relay AUTH: the active
     * account's signer stays the active one, and the owner never goes
     * through the foreground login that would have taken it over.
     */
    @Test fun ownerConnectedInTheBackgroundLeavesTheActiveSignerActive() = runBlocking {
        val fake = FakeBridge(connectAnswersAs = otherHex, backgroundAnswersAs = ownerHex)
        NIP46Service.bridge = fake
        assertEquals(otherHex, NIP46Service.connectForAccount(cfg(otherSigner), expectedPubkey = otherHex))

        assertTrue(NIP46Service.connectInBackground(cfg(ownerSigner), expectedPubkey = ownerHex))
        assertEquals(1, fake.backgroundConnects)
        assertEquals(1, fake.connects)
        assertTrue(NIP46Service.isConnected.value)
        assertEquals(otherHex, NIP46Service.connectedPubkey)
        assertEquals(otherSigner, NIP46Service.activeSignerKey)
        assertTrue(fake.dropped.isEmpty())
    }

    @Test fun backgroundOwnerSignerAnsweringForAnotherKeyIsDropped() = runBlocking {
        val fake = FakeBridge(backgroundAnswersAs = otherHex)
        NIP46Service.bridge = fake
        assertFalse(NIP46Service.connectInBackground(cfg(ownerSigner), expectedPubkey = ownerHex))
        assertEquals(listOf(ownerSigner), fake.dropped)
        assertFalse(NIP46Service.isConnected.value)
    }

    @Test fun sessionIsFoundByTheBunkerHostNotTheAccountKey() = runBlocking {
        // The stored signerPubkey is the account's own key; the Go core files
        // the session under the remote signer's key (the bunker link's host).
        val fake = FakeBridge(sessions = mutableMapOf(otherSigner to otherHex))
        NIP46Service.bridge = fake
        assertEquals(otherHex, NIP46Service.connectForAccount(cfg(otherSigner, stored = otherHex), expectedPubkey = otherHex))
        assertEquals(0, fake.connects)
        assertEquals(otherSigner, NIP46Service.activeSignerKey)
    }

    @Test fun reusedSessionForAnotherKeyIsDroppedAndLogsIn() = runBlocking {
        val fake = FakeBridge(sessions = mutableMapOf(otherSigner to ownerHex), connectAnswersAs = otherHex)
        NIP46Service.bridge = fake
        assertEquals(otherHex, NIP46Service.connectForAccount(cfg(otherSigner), expectedPubkey = otherHex))
        assertEquals(listOf(otherSigner), fake.dropped)
        assertEquals(1, fake.connects)
    }

    @Test fun detachKeepsTheSessionForSwitchingBack() = runBlocking {
        val fake = FakeBridge(sessions = mutableMapOf(ownerSigner to ownerHex, otherSigner to otherHex))
        NIP46Service.bridge = fake
        NIP46Service.connectForAccount(cfg(ownerSigner), ownerHex)
        NIP46Service.detachForAccountSwitch()
        assertFalse(NIP46Service.isConnected.value)
        NIP46Service.connectForAccount(cfg(otherSigner), otherHex)
        NIP46Service.detachForAccountSwitch()
        assertEquals(ownerHex, NIP46Service.connectForAccount(cfg(ownerSigner), ownerHex))
        assertTrue(fake.dropped.isEmpty())
        assertEquals(0, fake.connects)
    }

    @Test fun unansweredRequestWithFailedPingDropsTheSession() = runBlocking {
        val fake = FakeBridge(sessions = mutableMapOf(otherSigner to otherHex), pingResult = 1)
        NIP46Service.bridge = fake
        NIP46Service.connectForAccount(cfg(otherSigner), otherHex)
        NIP46Service.recheckSession(otherSigner)
        assertEquals(1, fake.pings)
        assertEquals(listOf(otherSigner), fake.dropped)
        assertFalse(NIP46Service.isConnected.value)
        assertNull(NIP46Service.connectedPubkey)
    }

    @Test fun unansweredRequestWithAnsweredPingKeepsTheSession() = runBlocking {
        val fake = FakeBridge(sessions = mutableMapOf(otherSigner to otherHex), pingResult = 0)
        NIP46Service.bridge = fake
        NIP46Service.connectForAccount(cfg(otherSigner), otherHex)
        NIP46Service.recheckSession(otherSigner)
        assertEquals(1, fake.pings)
        assertTrue(fake.dropped.isEmpty())
        assertTrue(NIP46Service.isConnected.value)
    }

    @Test fun lateFailureNeverTouchesAnAccountSwitchedTo() = runBlocking {
        val fake = FakeBridge(sessions = mutableMapOf(ownerSigner to ownerHex, otherSigner to otherHex), pingResult = 1)
        NIP46Service.bridge = fake
        NIP46Service.connectForAccount(cfg(otherSigner), otherHex)
        // The request went to the owner's session before the switch.
        NIP46Service.recheckSession(ownerSigner)
        assertEquals(0, fake.pings)
        assertTrue(fake.dropped.isEmpty())
        assertTrue(NIP46Service.isConnected.value)
    }

    @Test fun repairingWithAnotherSignerClosesTheOldSession() {
        assertEquals(ownerSigner, NIP46Service.sessionToClose(cfg(ownerSigner), cfg(otherSigner)))
        // Same signer: the Go core already replaced its session on connect.
        assertNull(NIP46Service.sessionToClose(cfg(ownerSigner), cfg(ownerSigner).copy(clientPubkey = "new")))
        assertNull(NIP46Service.sessionToClose(null, cfg(ownerSigner)))
    }

    @Test fun removingABunkerClosesItsSessionAndDetachesIfActive() = runBlocking {
        val fake = FakeBridge(sessions = mutableMapOf(otherSigner to otherHex))
        NIP46Service.bridge = fake
        NIP46Service.connectForAccount(cfg(otherSigner), otherHex)
        val key = NIP46Service.sessionToClose(cfg(otherSigner), null)
        assertEquals(otherSigner, key)
        NIP46Service.dropSession(key!!)
        assertEquals(listOf(otherSigner), fake.dropped)
        assertFalse(NIP46Service.isConnected.value)
    }
}
