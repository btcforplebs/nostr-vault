package com.nostrvault.ui.components

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.BlossomService
import com.nostrvault.service.BlossomService.MirrorPushResult
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.pushToMissing
import com.nostrvault.service.mirrorToMesh
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.fips.MeshMirrorOutcome
import com.nostrvault.fips.MeshMirrorResult
import com.nostrvault.ui.components.FeedMediaMirrorViewModel.MirrorState
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkAll
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The feed Mirror pill used to store the file on this phone only and then say
 * "Copied to your media servers". It now does what the iPhone's Mirror does
 * (store in the vault, then upload to every media server) and its label says
 * where the file actually went.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedMirrorPillTest {

    private val sha = "b".repeat(64)
    private val url = "https://cdn.example.com/$sha.jpg"

    private val blossom = mockk<BlossomService>(relaxed = true)
    private val cache = mockk<MediaCacheService>(relaxed = true)
    private val config = MutableStateFlow(HavenConfig(ownerNpub = "npub1owner"))

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        mockkStatic("com.nostrvault.service.BlossomServiceMirroringKt")
        mockkStatic("com.nostrvault.service.BlossomServiceMirrorMeshKt")
        coEvery { blossom.mirrorToMesh(any(), any(), any()) } returns emptyList()
        val store = mockk<ConfigStore>()
        every { store.config } returns config
        every { blossom.configStore } returns store
        every { blossom.localBlossomURL() } returns "http://localhost:4869"
        every { cache.isInLocalBlossom(any()) } returns false
    }

    @After fun tearDown() {
        Dispatchers.resetMain()
        unmockkAll()
    }

    private fun servers(vararg urls: String) {
        config.value = HavenConfig(ownerNpub = "npub1owner", blossomMirrors = urls.toList())
    }

    private fun viewModel() = FeedMediaMirrorViewModel(
        blossom, cache, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true),
    )

    /** mirror() hops to Dispatchers.IO, so wait (real time) for it to settle. */
    private fun FeedMediaMirrorViewModel.mirrorAndWait(u: String): MirrorState = runBlocking {
        mirror(u)
        withTimeout(5_000) { while (state.value is MirrorState.Mirroring) delay(5) }
        state.value
    }

    // ── The pill does the iPhone's two steps ──

    @Test fun `mirror stores locally then pushes to every server`() {
        servers("https://a.example.com", "https://b.example.com")
        coEvery { blossom.mirrorUrlToLocal(url) } returns sha
        coEvery { blossom.pushToMissing(sha) } returns MirrorPushResult.AllAccepted(2)

        val vm = viewModel().apply { onOpen(url) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.Everywhere)), vm.mirrorAndWait(url))
        coVerify(exactly = 1) { blossom.pushToMissing(sha) }
    }

    @Test fun `pushes the hash of the stored bytes, not one guessed from the URL`() {
        servers("https://a.example.com")
        val plain = "https://cdn.example.com/photo.jpg"
        coEvery { blossom.mirrorUrlToLocal(plain) } returns sha
        coEvery { blossom.pushToMissing(sha) } returns MirrorPushResult.AllAccepted(1)

        val vm = viewModel().apply { onOpen(plain) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.Everywhere)), vm.mirrorAndWait(plain))
        coVerify(exactly = 1) { blossom.pushToMissing(sha) }
    }

    @Test fun `some servers refusing is reported as a count`() {
        servers("https://a.example.com", "https://b.example.com", "https://c.example.com")
        coEvery { blossom.mirrorUrlToLocal(url) } returns sha
        coEvery { blossom.pushToMissing(sha) } returns MirrorPushResult.Partial(1, 3)

        val vm = viewModel().apply { onOpen(url) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.SomeServers(1, 3))), vm.mirrorAndWait(url))
    }

    @Test fun `every server failing still says it is saved on this phone`() {
        servers("https://a.example.com")
        coEvery { blossom.mirrorUrlToLocal(url) } returns sha
        coEvery { blossom.pushToMissing(sha) } returns MirrorPushResult.AllFailed(1)

        val vm = viewModel().apply { onOpen(url) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.ServersFailed)), vm.mirrorAndWait(url))
    }

    @Test fun `no servers added stops at the phone and pushes nothing`() {
        coEvery { blossom.mirrorUrlToLocal(url) } returns sha

        val vm = viewModel().apply { onOpen(url) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.OnPhoneOnly)), vm.mirrorAndWait(url))
        coVerify(exactly = 0) { blossom.pushToMissing(any()) }
    }

    @Test fun `a failed local save fails and pushes nothing`() {
        servers("https://a.example.com")
        coEvery { blossom.mirrorUrlToLocal(url) } returns null

        val vm = viewModel().apply { onOpen(url) }
        assertTrue(vm.mirrorAndWait(url) is MirrorState.Failed)
        coVerify(exactly = 0) { blossom.pushToMissing(any()) }
    }

    // ── Already in the vault when opened (G5) ──

    @Test fun `already in the vault opens as In vault, and a tap pushes without downloading again`() {
        servers("https://a.example.com")
        every { cache.isInLocalBlossom(sha) } returns true
        coEvery { blossom.pushToMissing(sha) } returns null // every server already had it

        val vm = viewModel().apply { onOpen(url) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.InVault)), vm.state.value)
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.Everywhere)), vm.mirrorAndWait(url))
        coVerify(exactly = 0) { blossom.mirrorUrlToLocal(any(), any(), any(), any(), any()) }
    }

    @Test fun `already in the vault with no servers is done`() {
        every { cache.isInLocalBlossom(sha) } returns true
        val vm = viewModel().apply { onOpen(url) }
        assertEquals(MirrorState.Mirrored(MirrorReport(MirrorOutcome.OnPhoneOnly)), vm.state.value)
    }

    // ── Words ──

    @Test fun `push results map to outcomes`() {
        assertEquals(MirrorOutcome.Everywhere, MirrorOutcome.of(null))
        assertEquals(MirrorOutcome.Everywhere, MirrorOutcome.of(MirrorPushResult.AllAccepted(2)))
        assertEquals(MirrorOutcome.SomeServers(1, 2), MirrorOutcome.of(MirrorPushResult.Partial(1, 2)))
        assertEquals(MirrorOutcome.OnPhoneOnly, MirrorOutcome.of(MirrorPushResult.NoOutsideServer))
        assertEquals(MirrorOutcome.ServersFailed, MirrorOutcome.of(MirrorPushResult.AllFailed(2)))
        assertEquals(MirrorOutcome.ServersFailed, MirrorOutcome.of(MirrorPushResult.NotOnDevice))
        assertEquals(MirrorOutcome.ServersFailed, MirrorOutcome.of(MirrorPushResult.SignerUnavailable))
    }

    @Test fun `only outcomes that reached every server claim the servers`() {
        assertEquals("Saved to your vault and your media servers", MirrorOutcome.Everywhere.spoken)
        assertEquals("Saved to your vault on this phone", MirrorOutcome.OnPhoneOnly.spoken)
        assertTrue(MirrorOutcome.SomeServers(1, 3).spoken.contains("1 of 3 media servers"))
        for (o in listOf(MirrorOutcome.ServersFailed, MirrorOutcome.OnPhoneOnly, MirrorOutcome.InVault)) {
            assertFalse(o.label, o.spoken.startsWith("Saved to your vault and"))
            assertFalse(o.label, o.label == "Mirrored")
        }
    }

    @Test fun `a tap can retry exactly the outcomes some server still lacks`() {
        assertFalse(MirrorOutcome.Everywhere.canRetry)
        assertFalse(MirrorOutcome.OnPhoneOnly.canRetry)
        assertTrue(MirrorOutcome.SomeServers(1, 2).canRetry)
        assertTrue(MirrorOutcome.ServersFailed.canRetry)
        assertTrue(MirrorOutcome.InVault.canRetry)
    }
    // ── Over FIPS to the mesh devices the owner's 10063 lists ──

    private val mac = "npub1mac"
    private val kiosk = "npub1kiosk"

    @Test fun `each listed mesh device is reported by its My Devices name`() {
        config.value = HavenConfig(
            ownerNpub = "npub1owner", blossomMirrors = listOf("https://a.example.com"),
            fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(mac, DeviceRole.MAC, name = "Office Mac"))),
        )
        coEvery { blossom.mirrorUrlToLocal(url) } returns sha
        coEvery { blossom.pushToMissing(sha) } returns MirrorPushResult.AllAccepted(1)
        coEvery { blossom.mirrorToMesh(sha, "image/jpeg", any()) } returns listOf(
            MeshMirrorResult(mac, DeviceRole.MAC, MeshMirrorOutcome.SENT),
            MeshMirrorResult(kiosk, DeviceRole.HOME_VAULT, MeshMirrorOutcome.WAITING),
        )

        val vm = viewModel().apply { onOpen(url) }
        val report = (vm.mirrorAndWait(url) as MirrorState.Mirrored).report
        assertEquals(
            listOf(MeshDeviceLine("Office Mac", MeshMirrorOutcome.SENT), MeshDeviceLine("Mobile vault", MeshMirrorOutcome.WAITING)),
            report.mesh,
        )
        assertEquals("Mirrored · 1 of 2 devices", report.label)
        assertTrue(report.spoken, report.spoken.contains("Office Mac: sent over the mesh"))
        assertTrue(report.spoken, report.spoken.contains("Mobile vault: waiting"))
        assertFalse(report.complete)
        assertTrue(report.canRetry)
    }

    @Test fun `no mesh step when the local save failed`() {
        servers("https://a.example.com")
        coEvery { blossom.mirrorUrlToLocal(url) } returns null
        viewModel().apply { onOpen(url) }.mirrorAndWait(url)
        coVerify(exactly = 0) { blossom.mirrorToMesh(any(), any(), any()) }
    }

    @Test fun `every device sent and every server is green, a refusal is not retried`() {
        val sent = MirrorReport(MirrorOutcome.Everywhere, listOf(MeshDeviceLine("Office Mac", MeshMirrorOutcome.SENT)))
        assertTrue(sent.complete)
        assertFalse(sent.canRetry)
        assertEquals("Mirrored · 1 of 1 device", sent.label)
        val refused = MirrorReport(MirrorOutcome.Everywhere, listOf(MeshDeviceLine("Office Mac", MeshMirrorOutcome.REFUSED)))
        assertFalse(refused.complete)
        assertFalse(refused.canRetry)
        val full = MirrorReport(MirrorOutcome.Everywhere, listOf(MeshDeviceLine("Office Mac", MeshMirrorOutcome.NOT_QUEUED)))
        assertTrue(full.canRetry)
        assertEquals("Mirrored", MirrorReport(MirrorOutcome.Everywhere).label)
    }
}
