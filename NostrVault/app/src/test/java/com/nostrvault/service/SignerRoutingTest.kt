package com.nostrvault.service

import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #168 parity: owner-forced events must never reach the active account's
 * signer, and a bunker answering for the wrong key must never count as
 * connected.
 */
class SignerRoutingTest {
    private val ownerNpub = "npub1owner"
    private val otherNpub = "npub1other"
    private val ownerHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val ownerSigner = "1".repeat(64)
    private val otherSigner = "2".repeat(64)

    private fun config(ownerMode: String, otherMode: String = "nip46") = HavenConfig(
        ownerNpub = ownerNpub,
        activeAccountNpub = otherNpub,
        accountSigningModes = mapOf(ownerNpub to ownerMode, otherNpub to otherMode),
        accountBunkerConfigs = buildMap {
            put(otherNpub, AccountBunkerConfig(bunkerURI = "bunker://$otherSigner?relay=wss://r", signerPubkey = otherSigner))
            if (ownerMode == "nip46") put(ownerNpub, AccountBunkerConfig(bunkerURI = "bunker://$ownerSigner?relay=wss://r", signerPubkey = ownerSigner))
        },
    )

    @Test fun ownerForcedEventGoesToTheOwnersBunkerNotTheActiveOne() {
        val route = SignerRouting.route(config("nip46"), forceOwner = true, ownerHex = ownerHex, activeHex = otherHex)
        assertEquals(SignerRoute.BunkerSession(ownerSigner), route)
    }

    @Test fun ownerForcedEventWithLocalOwnerSignsLocally() {
        val route = SignerRouting.route(config("local"), forceOwner = true, ownerHex = ownerHex, activeHex = otherHex)
        assertEquals(SignerRoute.Local(asOwner = true), route)
    }

    @Test fun ownerForcedEventWithAmberOwnerAsksAmberAsOwner() {
        val route = SignerRouting.route(config("amber"), forceOwner = true, ownerHex = ownerHex, activeHex = otherHex)
        assertEquals(SignerRoute.Amber(asOwner = true), route)
    }

    @Test fun ownerBunkerWithoutSignerKeyFailsClosed() {
        val cfg = config("nip46").let {
            it.copy(accountBunkerConfigs = it.accountBunkerConfigs + (ownerNpub to AccountBunkerConfig(bunkerURI = "bunker://x?relay=wss://r")))
        }
        val route = SignerRouting.route(cfg, forceOwner = true, ownerHex = ownerHex, activeHex = otherHex)
        assertTrue(route is SignerRoute.Unavailable)
    }

    @Test fun normalEventUsesTheActiveAccountsBunker() {
        val route = SignerRouting.route(config("nip46"), forceOwner = false, ownerHex = ownerHex, activeHex = otherHex)
        assertEquals(SignerRoute.ActiveBunker, route)
    }

    // Connect-time key check

    private class FakeBridge(val answersAs: String?) : NIP46Service.Bridge {
        val dropped = mutableListOf<String>()
        override fun connect(clientSecretKey: String, bunkerUrl: String) = answersAs
        override fun activate(signerPubkey: String): String? = null
        override fun drop(signerPubkey: String) { dropped += signerPubkey }
        override fun ping() = 0
    }

    @After fun resetBridge() { NIP46Service.disconnectForTest() }

    @Test fun wrongKeyBunkerIsRejectedAndDroppedOnConnect() = runBlocking {
        val fake = FakeBridge(answersAs = ownerHex)
        NIP46Service.bridge = fake
        val cfg = AccountBunkerConfig(bunkerURI = "bunker://$otherSigner?relay=wss://r", signerPubkey = otherSigner)
        val result = NIP46Service.connectForAccount(cfg, expectedPubkey = otherHex)
        assertNull(result)
        assertFalse(NIP46Service.isConnected.value)
        assertNull(NIP46Service.connectedPubkey)
        assertEquals(listOf(otherSigner), fake.dropped)
    }

    @Test fun rightKeyBunkerConnects() = runBlocking {
        NIP46Service.bridge = FakeBridge(answersAs = otherHex)
        val cfg = AccountBunkerConfig(bunkerURI = "bunker://$otherSigner?relay=wss://r", signerPubkey = otherSigner)
        assertEquals(otherHex, NIP46Service.connectForAccount(cfg, expectedPubkey = otherHex))
        assertTrue(NIP46Service.isConnected.value)
    }
}
