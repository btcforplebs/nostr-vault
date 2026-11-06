package com.nostrvault.fips

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
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
 * Every engine restart drops every mesh link, seeds included. The Moto (2026-11-06) restarted twice for one device
 * link (setPeers and the My Devices watch both restarted) and once per tap on the middle server it already had.
 * Now a restart happens only when the engine would start differently: one link = 1 restart, a no-op tap = 0.
 */
class FipsMeshRestartTest {
    private val owner = "npub1owner"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"

    private val config = MutableStateFlow(
        HavenConfig(
            ownerNpub = owner, fipsMeshEnabled = true,
            fipsMesh = FipsMeshSettings(middleServer = FipsMeshSettings.MIDDLE_PUBLIC),
        ),
    )
    private val configStore = mockk<ConfigStore>(relaxed = true) {
        every { config } returns this@FipsMeshRestartTest.config
        // A real write, so the My Devices watch sees the change as it would on a phone.
        coEvery { updateAsync(any()) } coAnswers {
            val transform = firstArg<(HavenConfig) -> HavenConfig>()
            this@FipsMeshRestartTest.config.value = transform(this@FipsMeshRestartTest.config.value)
        }
    }

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

    private suspend fun running(): FipsMeshManager =
        FipsMeshManager(CredentialStore, configStore, CoroutineScope(UnconfinedTestDispatcher()), mockk(relaxed = true))
            .also { assertTrue(it.start(persist = false)) }

    /** Restarts that have happened once the watch (on IO) has had time to act too. */
    private fun assertRestarts(n: Int) {
        if (n > 0) verify(timeout = 5_000, atLeast = n) { FipsBridge.stop() }
        Thread.sleep(300)
        verify(exactly = n) { FipsBridge.stop() }
    }

    @Test fun `linking a device restarts the engine once`() = runTest {
        val m = running()
        // PairDeviceViewModel.storeNow: the label first, then the peers.
        configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(devices = listOf(FipsDevice(mac, DeviceRole.MAC, linkedBy = owner)))) }
        m.setPeers(listOf(mac))
        assertRestarts(1)
    }

    @Test fun `setting the peers it already has restarts nothing`() = runTest {
        config.value = config.value.copy(fipsPeers = listOf(mac))
        val m = running()
        m.setPeers(listOf(mac))
        m.setPeers(listOf(" $mac ", mac))
        assertRestarts(0)
    }

    @Test fun `tapping the middle server already chosen restarts nothing`() = runTest {
        val m = running()
        m.setAdvanced(FipsMeshSettings.DEFAULT_FINDER_RELAYS, FipsMeshSettings.MIDDLE_PUBLIC)
        m.setAdvanced(emptyList(), FipsMeshSettings.MIDDLE_PUBLIC)
        assertRestarts(0)
    }

    @Test fun `a new middle server or new finder relays still restart`() = runTest {
        val m = running()
        m.setAdvanced(emptyList(), FipsMeshSettings.MIDDLE_NONE)
        assertRestarts(1)
        m.setAdvanced(listOf("wss://relay.example"), FipsMeshSettings.MIDDLE_NONE)
        assertRestarts(2)
        m.setAdvanced(listOf("wss://relay.example"), FipsMeshSettings.MIDDLE_PUBLIC)
        assertRestarts(3)
    }

    @Test fun `removing a device still restarts`() = runTest {
        config.value = config.value.copy(fipsPeers = listOf(mac, phone))
        val m = running()
        m.setPeers(listOf(mac))
        assertRestarts(1)
    }

    @Test fun `the rule restarts for each start-time setting and not for the allowance`() {
        val base = HavenConfig(ownerNpub = owner, fipsPeers = listOf(mac))
        val started = MeshEnginePlan.options(base, null, maxServeBytes = 1234)
        assertFalse(MeshEnginePlan.restartNeeded(started, false, base, null))
        assertTrue(MeshEnginePlan.restartNeeded(null, false, base, null))
        assertTrue(MeshEnginePlan.restartNeeded(started, false, base.copy(fipsPeers = listOf(mac, phone)), null))
        assertTrue(MeshEnginePlan.restartNeeded(started, false, base.copy(homeVaultNpub = phone), null))
        assertTrue(MeshEnginePlan.restartNeeded(started, false, base.copy(fipsMesh = FipsMeshSettings(middleServer = FipsMeshSettings.MIDDLE_PUBLIC)), null))
        assertTrue(MeshEnginePlan.restartNeeded(started, false, base.copy(fipsMesh = FipsMeshSettings(finderRelays = listOf("wss://relay.example"))), null))
        assertTrue(MeshEnginePlan.restartNeeded(started, true, base, null))
    }
}
