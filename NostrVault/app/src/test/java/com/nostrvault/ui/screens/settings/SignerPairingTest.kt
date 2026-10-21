package com.nostrvault.ui.screens.settings

import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NIP46Service
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Connect Remote Signer on an account already here (iOS ConnectSignerSheetView):
 * the signer must answer as that account's own key, and nothing is stored
 * until it has.
 */
class SignerPairingTest {
    private val accountHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val signer = "1".repeat(64)
    private val npub = HavenBridge.encodeNpub(accountHex)!!
    private val uri = "bunker://$signer?relay=wss://r"

    private class FakeBridge(val answersAs: String?) : NIP46Service.Bridge {
        val dropped = mutableListOf<String>()
        var connects = 0
        var backgroundConnects = 0
        override fun connect(clientSecretKey: String, bunkerUrl: String): String? { connects++; return answersAs }
        override fun connectBackground(clientSecretKey: String, bunkerUrl: String): String? { backgroundConnects++; return answersAs }
        override fun activate(signerPubkey: String): String? = null
        override fun drop(signerPubkey: String) { dropped += signerPubkey }
        override fun ping() = 0
        override fun signWith(signerPubkey: String, eventJson: String): String? = null
    }

    private class FakeStore {
        val bunkers = mutableMapOf<String, AccountBunkerConfig>()
        val modes = mutableMapOf<String, String>()
        val store = SignerPairing.Store(
            setBunkerConfig = { npub, cfg -> bunkers[npub] = cfg },
            setSigningMode = { npub, mode -> modes[npub] = mode },
        )
    }

    @After fun reset() { NIP46Service.disconnectForTest() }

    private fun pair(active: String, store: FakeStore) = runBlocking {
        SignerPairing.pair(npub, uri, "sk", "pk", activeHexPubkey = active, store = store.store)
    }

    @Test fun aSignerForThisAccountIsStoredWithRemoteSigning() {
        val fake = FakeBridge(answersAs = accountHex).also { NIP46Service.bridge = it }
        val store = FakeStore()
        assertNull(pair(active = accountHex, store))
        assertEquals(1, fake.connects)
        val cfg = store.bunkers.getValue(npub)
        assertEquals(uri, cfg.bunkerURI)
        assertEquals(accountHex, cfg.signerPubkey)
        assertEquals("sk" to "pk", cfg.clientSecretKey to cfg.clientPubkey)
        assertEquals("nip46", store.modes[npub])
    }

    @Test fun aSignerForAnotherAccountIsRefusedAndNothingIsStored() {
        val fake = FakeBridge(answersAs = otherHex).also { NIP46Service.bridge = it }
        val store = FakeStore()
        val problem = pair(active = accountHex, store)
        assertEquals("This bunker signs as ${otherHex.take(8)}…, not this account", problem)
        assertTrue(store.bunkers.isEmpty())
        assertTrue(store.modes.isEmpty())
        // Its session is closed, so it cannot answer for anyone.
        assertEquals(listOf(signer), fake.dropped)
    }

    @Test fun anAccountThatIsNotActivePairsInTheBackground() {
        val fake = FakeBridge(answersAs = accountHex).also { NIP46Service.bridge = it }
        val store = FakeStore()
        assertNull(pair(active = otherHex, store))
        // The active account's live session is left alone.
        assertEquals(0, fake.connects)
        assertEquals(1, fake.backgroundConnects)
        assertEquals("nip46", store.modes[npub])
        assertEquals(uri, store.bunkers.getValue(npub).bunkerURI)
    }

    @Test fun anAccountThatIsNotActiveStillRefusesAnotherKey() {
        FakeBridge(answersAs = otherHex).also { NIP46Service.bridge = it }
        val store = FakeStore()
        assertEquals(SignerPairing.NOT_REACHED, pair(active = otherHex, store))
        assertTrue(store.bunkers.isEmpty())
        assertTrue(store.modes.isEmpty())
    }

    @Test fun aSignerThatDoesNotAnswerLeavesTheAccountAsItWas() {
        FakeBridge(answersAs = null).also { NIP46Service.bridge = it }
        val store = FakeStore()
        assertEquals("Could not reach the bunker", pair(active = accountHex, store))
        assertEquals(SignerPairing.NOT_REACHED, pair(active = otherHex, store))
        assertTrue(store.bunkers.isEmpty())
        assertTrue(store.modes.isEmpty())
    }

    @Test fun aBrokenNpubNeverReachesTheSigner() = runBlocking {
        val fake = FakeBridge(answersAs = accountHex).also { NIP46Service.bridge = it }
        val store = FakeStore()
        assertEquals(SignerPairing.BAD_NPUB, SignerPairing.pair("npub1nope", uri, "sk", "pk", accountHex, store.store))
        assertEquals(0, fake.connects + fake.backgroundConnects)
        assertTrue(store.bunkers.isEmpty())
    }
}
