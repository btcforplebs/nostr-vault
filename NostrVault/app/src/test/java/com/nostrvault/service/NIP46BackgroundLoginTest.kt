package com.nostrvault.service

import com.nostrvault.relay.AccountBunkerConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The owner's bunker while another account is active: an owner-forced sign
 * opens it in the background and tries once more, and that login never
 * stalls or disturbs the active account's session.
 */
class NIP46BackgroundLoginTest {
    private val ownerHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val ownerSigner = "1".repeat(64)
    private val otherSigner = "2".repeat(64)
    private val event = """{"kind":22242}"""

    private class FakeBridge(
        val connectAnswersAs: String? = null,
        val backgroundAnswersAs: String? = null,
        /** signWith answers only once the background login has landed. */
        val signsAfterBackgroundLogin: Boolean = true,
    ) : NIP46Service.Bridge {
        val dropped = mutableListOf<String>()
        var backgroundConnects = 0
        var signs = 0
        /** When set, connectBackground blocks until it is counted down. */
        var backgroundStarted = CountDownLatch(1)
        var backgroundRelease: CountDownLatch? = null
        override fun connect(clientSecretKey: String, bunkerUrl: String) = connectAnswersAs
        override fun connectBackground(clientSecretKey: String, bunkerUrl: String): String? {
            backgroundConnects++
            backgroundStarted.countDown()
            backgroundRelease?.await(10, TimeUnit.SECONDS)
            return backgroundAnswersAs
        }
        override fun activate(signerPubkey: String): String? = null
        override fun drop(signerPubkey: String) { dropped += signerPubkey }
        override fun ping() = 0
        override fun signWith(signerPubkey: String, eventJson: String): String? {
            signs++
            val live = backgroundConnects > 0 && backgroundAnswersAs != null
            return if (signsAfterBackgroundLogin && live) """{"id":"signed","pubkey":"$signerPubkey"}""" else null
        }
    }

    private fun cfg(signer: String) =
        AccountBunkerConfig(bunkerURI = "bunker://$signer?relay=wss://r", signerPubkey = signer)

    @After fun reset() { NIP46Service.disconnectForTest() }

    /**
     * After a restart with another account active, the first owner-forced
     * sign (the /chat AUTH, counts, Blossom, a list) finds no owner session:
     * it logs the owner's bunker in and signs on the second try.
     */
    @Test fun ownerSignOpensTheOwnersBunkerAndRetriesOnce() = runBlocking {
        val fake = FakeBridge(backgroundAnswersAs = ownerHex)
        NIP46Service.bridge = fake
        val signed = NIP46Service.signEventWithWarmUp(ownerSigner, event, warm = cfg(ownerSigner), expectedPubkey = ownerHex)
        assertTrue(signed?.contains("signed") == true)
        assertEquals(1, fake.backgroundConnects)
        assertEquals(2, fake.signs)
        assertFalse(NIP46Service.isConnected.value)
    }

    @Test fun ownerSignWithNothingToWarmFailsAfterOneTry() = runBlocking {
        val fake = FakeBridge(backgroundAnswersAs = ownerHex)
        NIP46Service.bridge = fake
        assertNull(NIP46Service.signEventWithWarmUp(ownerSigner, event, warm = null, expectedPubkey = ownerHex))
        assertEquals(0, fake.backgroundConnects)
        assertEquals(1, fake.signs)
    }

    /** A refusing or unreachable signer gets one login and no second sign. */
    @Test fun ownerSignDoesNotRetryWhenTheLoginFails() = runBlocking {
        val fake = FakeBridge(backgroundAnswersAs = null)
        NIP46Service.bridge = fake
        assertNull(NIP46Service.signEventWithWarmUp(ownerSigner, event, warm = cfg(ownerSigner), expectedPubkey = ownerHex))
        assertEquals(1, fake.backgroundConnects)
        assertEquals(1, fake.signs)
    }

    @Test fun ownerSignDoesNotRetryWhenTheSignerAnswersForAnotherKey() = runBlocking {
        val fake = FakeBridge(backgroundAnswersAs = otherHex)
        NIP46Service.bridge = fake
        assertNull(NIP46Service.signEventWithWarmUp(ownerSigner, event, warm = cfg(ownerSigner), expectedPubkey = ownerHex))
        assertEquals(1, fake.signs)
        assertEquals(listOf(ownerSigner), fake.dropped)
    }

    /**
     * A sleeping owner signer can take the whole login timeout to answer.
     * That wait must not hold the lock the active account's connect needs,
     * or its bunker signs, DM decrypts and switches stall behind the owner.
     */
    @Test fun slowBackgroundLoginDoesNotBlockTheActiveAccountsConnect() = runBlocking {
        val fake = FakeBridge(connectAnswersAs = otherHex, backgroundAnswersAs = ownerHex)
        fake.backgroundRelease = CountDownLatch(1)
        NIP46Service.bridge = fake
        val background = launch(Dispatchers.IO) { NIP46Service.connectInBackground(cfg(ownerSigner), ownerHex) }
        assertTrue(fake.backgroundStarted.await(5, TimeUnit.SECONDS))
        try {
            val connected = withTimeout(2_000) { NIP46Service.connectForAccount(cfg(otherSigner), expectedPubkey = otherHex) }
            assertEquals(otherHex, connected)
        } finally {
            fake.backgroundRelease!!.countDown()
            background.join()
        }
        assertEquals(otherHex, NIP46Service.connectedPubkey)
        assertEquals(1, fake.backgroundConnects)
    }

    /** lastError describes the active account's last request; a background failure is not that. */
    @Test fun backgroundLoginFailureLeavesLastErrorAlone() = runBlocking {
        NIP46Service.bridge = FakeBridge(backgroundAnswersAs = null)
        assertFalse(NIP46Service.connectInBackground(cfg(ownerSigner), ownerHex))
        assertNull(NIP46Service.lastError.value)
        NIP46Service.bridge = FakeBridge(backgroundAnswersAs = otherHex)
        assertFalse(NIP46Service.connectInBackground(cfg(ownerSigner), ownerHex))
        assertNull(NIP46Service.lastError.value)
    }

    /**
     * Owner and active account on one bunker host (one signer app holding
     * both keys): the Go core's no-op for the live session answers as the
     * active account. That is not a wrong signer to drop; dropping it would
     * cut the session the active account is signing through.
     */
    @Test fun sharedHostAnsweringAsTheActiveAccountKeepsItsSession() = runBlocking {
        val fake = FakeBridge(connectAnswersAs = otherHex, backgroundAnswersAs = otherHex)
        NIP46Service.bridge = fake
        assertEquals(otherHex, NIP46Service.connectForAccount(cfg(otherSigner), expectedPubkey = otherHex))
        assertFalse(NIP46Service.connectInBackground(cfg(otherSigner), ownerHex))
        assertTrue(fake.dropped.isEmpty())
        assertTrue(NIP46Service.isConnected.value)
        assertEquals(otherHex, NIP46Service.connectedPubkey)
    }
}
