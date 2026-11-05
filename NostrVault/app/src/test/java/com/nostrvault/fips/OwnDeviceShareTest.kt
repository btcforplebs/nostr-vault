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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Logen 2026-11-05 (iPhone #1779): with a phone linked, this vault is shared with own devices even with Share on
 * mesh off, so that phone's sends (#1778) arrive. Relay port for own devices only; the stranger door stays shut.
 * Share on is still full sharing.
 */
class OwnDeviceShareTest {
    private val owner = "npub1owner"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"

    private fun config(vararg devices: FipsDevice, share: Boolean = false) = HavenConfig(
        ownerNpub = owner, fipsShareRelay = share, fipsPeers = devices.map { it.npub },
        fipsMesh = FipsMeshSettings(devices = devices.toList()),
    )

    private val withPhone = config(FipsDevice(phone, DeviceRole.PHONE, linkedBy = owner))
    private val config = MutableStateFlow(HavenConfig(ownerNpub = owner))
    private val configStore = mockk<ConfigStore>(relaxed = true) { every { config } returns this@OwnDeviceShareTest.config }
    private val relayPort = HavenConfig().relayPort

    @Before fun setUp() {
        mockkObject(CredentialStore, FipsBridge, HavenBridge)
        every { FipsBridge.isAvailable } returns true
        every { CredentialStore.readMeshNsec() } returns "nsec1saved"
        every { FipsBridge.start(any(), any()) } returns 0
        every { FipsBridge.stop() } returns Unit
        every { FipsBridge.export(any()) } returns 0
        every { FipsBridge.status() } returns FipsStatus(running = true)
        every { HavenBridge.setMeshServing(any()) } returns Unit
    }

    @After fun tearDown() = unmockkAll()

    private fun manager() = FipsMeshManager(CredentialStore, configStore, CoroutineScope(UnconfinedTestDispatcher()), mockk(relaxed = true))

    @Test fun `the rule follows iPhone`() {
        assertTrue(MeshEnginePlan.sharesWithLinkedPhones(withPhone))
        assertFalse(MeshEnginePlan.sharesWithLinkedPhones(config()))
        assertFalse(MeshEnginePlan.sharesWithLinkedPhones(config(FipsDevice(mac, DeviceRole.MAC, linkedBy = owner))))
        // Share on is full sharing, not this.
        assertFalse(MeshEnginePlan.sharesWithLinkedPhones(withPhone.copy(fipsShareRelay = true)))
        // Another account's phone gets none of the owner's sends, so it is no reason to share.
        assertFalse(MeshEnginePlan.sharesWithLinkedPhones(config(FipsDevice(phone, DeviceRole.PHONE, linkedBy = "npub1other"))))
    }

    @Test fun `with a phone linked and Share off, own devices get the relay port and the door stays shut`() = runTest {
        config.value = withPhone
        manager().start(persist = false)
        verify(exactly = 1) { FipsBridge.export(relayPort) }
        verify(exactly = 0) { HavenBridge.setMeshServing(true) }
    }

    @Test fun `with no phone linked and Share off nothing is shared`() = runTest {
        config.value = config(FipsDevice(mac, DeviceRole.MAC, linkedBy = owner))
        manager().start(persist = false)
        verify(exactly = 0) { FipsBridge.export(any()) }
    }

    @Test fun `Share on is still full sharing, door and all`() = runTest {
        config.value = withPhone.copy(fipsShareRelay = true)
        manager().start(persist = false)
        verify(exactly = 1) { HavenBridge.setMeshServing(true) }
        verify(exactly = 1) { FipsBridge.export(relayPort) }
    }

    @Test fun `a phone linked while the engine runs starts the share`() = runTest {
        val m = manager()
        m.start(persist = false)
        verify(exactly = 0) { FipsBridge.export(any()) }
        config.value = withPhone
        verify(timeout = 5_000, exactly = 1) { FipsBridge.export(relayPort) }
        verify(exactly = 0) { HavenBridge.setMeshServing(true) }
    }

    @Test fun `the copy after a link adds nothing when a linked phone already shares`() = runTest {
        config.value = withPhone
        val m = manager()
        m.start(persist = false)
        assertTrue(m.shareForCopy())
        verify(exactly = 1) { FipsBridge.export(relayPort) }
    }
}
