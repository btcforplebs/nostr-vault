package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test

/**
 * The inbox's Retry (iOS retryWaitingForSigner) runs one more pass over the
 * messages the signer couldn't open, while the automatic drain keeps its stop:
 * blocked with nothing new queued, it does not ask the signer again.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DMSignerRetryTest {
    private val owner = "npub1owner"
    private val config = MutableStateFlow(HavenConfig(ownerNpub = owner, accountSigningModes = mapOf(owner to "amber")))
    private lateinit var service: DMService

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        mockkObject(CredentialStore)
        every { CredentialStore.getKeychainPassword(any()) } returns null
        every { CredentialStore.getNsec(any()) } returns null
        every { CredentialStore.getCredentialHexKey(any()) } returns null
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns config
        every { configStore.accountSwitches } returns emptyFlow()
        service = DMService(
            configStore = configStore,
            credentialStore = CredentialStore,
            nostrService = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            feedService = stubFeedService(),
        )
    }

    @After
    fun tearDown() {
        unmockkObject(CredentialStore)
        Dispatchers.resetMain()
    }

    /** One queued message, left blocked the way a failed silent decrypt leaves it. */
    private fun blockedWithOneQueued() {
        // A kind the drain treats as done, so a pass that runs empties the queue.
        service.pendingDecryptQueue.add(buildJsonObject { put("id", "e".repeat(64)); put("kind", 7) })
        service._decryptBlocked.value = true
        service.lastBlockedSize = service.pendingDecryptQueue.size
    }

    @Test
    fun `the automatic drain does not ask again while blocked with nothing new`() = runTest {
        blockedWithOneQueued()
        service.decryptPending()
        assertEquals(1, service.pendingDecryptQueue.size)
    }

    @Test
    fun `Retry runs one more pass over what the signer could not open`() = runTest {
        blockedWithOneQueued()
        service.retryWaitingForSigner()
        assertEquals(0, service.pendingDecryptQueue.size)
        assertFalse(service.decryptBlocked.value)
    }

    @Test
    fun `Retry asks Amber once, silently, and stops when it still cannot open`() = runTest {
        val amber = mockk<AmberSignerService>(relaxed = true)
        io.mockk.coEvery { amber.nip44Decrypt(any(), any(), any()) } returns null
        service = DMService(
            configStore = mockk<ConfigStore>(relaxed = true) {
                every { config } returns this@DMSignerRetryTest.config
                every { accountSwitches } returns emptyFlow()
            },
            credentialStore = CredentialStore,
            nostrService = mockk(relaxed = true),
            amberSignerService = amber,
            feedService = stubFeedService(),
        )
        repeat(2) { n ->
            service.pendingDecryptQueue.add(buildJsonObject {
                put("id", "$n".repeat(64)); put("kind", 1059); put("pubkey", "c".repeat(64)); put("content", "x")
            })
        }
        service._decryptBlocked.value = true
        service.lastBlockedSize = 2

        service.retryWaitingForSigner()
        io.mockk.coVerify(exactly = 1) { amber.nip44Decrypt(any(), any(), true) }
        io.mockk.coVerify(exactly = 0) { amber.nip44Decrypt(any(), any(), false) }
        assertEquals(2, service.pendingDecryptQueue.size)
        assertEquals(true, service.decryptBlocked.value)

        // The guard is back: the next automatic pass asks nothing.
        service.decryptPending()
        io.mockk.coVerify(exactly = 1) { amber.nip44Decrypt(any(), any(), any()) }
    }

    @Test
    fun `Retry does nothing outside signer mode`() = runTest {
        blockedWithOneQueued()
        config.value = HavenConfig(ownerNpub = owner, ownerHexKey = "b".repeat(64))
        service.retryWaitingForSigner()
        assertEquals(1, service.pendingDecryptQueue.size)
    }

    @Test
    fun `the banner says what iOS says`() {
        assertEquals("1 message is waiting for your signer to open it.", com.nostrvault.ui.screens.dm.DMSignerWaiting.text(1))
        assertEquals("3 messages are waiting for your signer to open them.", com.nostrvault.ui.screens.dm.DMSignerWaiting.text(3))
    }
}
