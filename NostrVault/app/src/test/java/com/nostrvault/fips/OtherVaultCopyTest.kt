package com.nostrvault.fips

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkAll
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * "Copy from my other vault" over the mesh (twin of iOS #1776): the source shares with its own devices for the copy
 * window with Share off, and the new phone dials for a minute before it falls back to the relays.
 */
class OtherVaultCopyTest {
    private val config = MutableStateFlow(HavenConfig())
    private val configStore = mockk<ConfigStore>(relaxed = true) { every { config } returns this@OtherVaultCopyTest.config }
    private val link = mockk<OtherVaultLink>(relaxed = true)

    @Before fun setUp() {
        mockkObject(CredentialStore, FipsBridge, HavenBridge)
        every { FipsBridge.isAvailable } returns true
        every { CredentialStore.readMeshNsec() } returns "nsec1saved"
        every { FipsBridge.start(any(), any()) } returns 0
        every { FipsBridge.export(any()) } returns 0
        every { FipsBridge.status() } returns FipsStatus(running = true)
        every { HavenBridge.setMeshServing(any()) } returns Unit
    }

    @After fun tearDown() = unmockkAll()

    private fun manager() = FipsMeshManager(CredentialStore, configStore, CoroutineScope(UnconfinedTestDispatcher()), link)

    @Test fun `the new phone dials six times over a minute, every ten seconds`() {
        val tries = generateSequence(0L) { it + OtherVaultCopy.DIAL_RETRY_S }.takeWhile { OtherVaultCopy.dialsAgain(0, it) }.count() + 1
        assertEquals(6, tries)
        assertTrue(OtherVaultCopy.dialsAgain(100, 140))
        assertFalse(OtherVaultCopy.dialsAgain(100, 150))
    }

    @Test fun `the source shares after a link only when the mesh runs and Share is off`() {
        assertTrue(OtherVaultCopy.sharesAfterLink(meshOn = true, alreadySharing = false))
        assertFalse(OtherVaultCopy.sharesAfterLink(meshOn = true, alreadySharing = true))
        assertFalse(OtherVaultCopy.sharesAfterLink(meshOn = false, alreadySharing = false))
        assertEquals(15 * 60 * 1000L, OtherVaultCopy.SHARE_WINDOW_MS)
    }

    @Test fun `with Share off the relay port goes to own devices and the stranger door stays shut`() = runTest {
        assertTrue(manager().shareForCopy())
        verify(exactly = 1) { FipsBridge.export(HavenConfig().relayPort) }
        verify(exactly = 0) { HavenBridge.setMeshServing(true) }
    }

    @Test fun `a restart inside the window keeps the copy share`() = runTest {
        val m = manager()
        m.shareForCopy()
        m.start(persist = false)
        verify(exactly = 2) { FipsBridge.export(HavenConfig().relayPort) }
        verify(exactly = 0) { HavenBridge.setMeshServing(true) }
    }

    @Test fun `without a link a restart shares nothing`() = runTest {
        manager().start(persist = false)
        verify(exactly = 0) { FipsBridge.export(any()) }
    }

    @Test fun `with Share on there is nothing more to open, and the line still shows`() = runTest {
        config.value = HavenConfig(fipsShareRelay = true)
        assertTrue(manager().shareForCopy())
        verify(exactly = 0) { FipsBridge.export(any()) }
    }

    @Test fun `with the mesh off nothing is shared and no line shows`() = runTest {
        every { FipsBridge.status() } returns FipsStatus(running = false)
        assertFalse(manager().shareForCopy())
        verify(exactly = 0) { FipsBridge.export(any()) }
    }

    @Test fun `an engine start brings back the other vault's lasting address`() = runTest {
        manager().start(persist = false)
        verify(exactly = 1) { link.restore(any()) }
    }
}
