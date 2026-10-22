package com.nostrvault.fips

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HomeVaultSenderTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val kiosk = "npub1" + "q".repeat(58)

    private fun sender(): HomeVaultSender {
        val dir = tmp.newFolder()
        val context = mockk<Context> { every { filesDir } returns dir }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(HavenConfig(homeVaultNpub = kiosk))
        return HomeVaultSender(context, config).apply {
            ownerHex = { "a".repeat(64) }
            ownerIsActive = { true }
        }
    }

    @Test
    fun `a failure outside any item is reported, not thrown`() {
        val s = sender()
        // The offer itself passes; the drain that follows hits the failure.
        var calls = 0
        s.ownerIsActive = { if (calls++ == 0) true else throw IllegalStateException("disk gone") }
        // Queues on the sender's own scope, then drains there; the failure
        // must land on the card, not escape and kill the app.
        s.offerEvent("e1", "a".repeat(64), "{}")
        val deadline = System.currentTimeMillis() + 5_000
        while (s.state.value.lastProblem == null && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals("Could not update the queue", s.state.value.lastProblem)
        assertEquals(1, s.state.value.waiting)
    }

    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"

    private fun macOnlySender(sendNotes: Boolean = true, sendMedia: Boolean = true): HomeVaultSender {
        val context = mockk<Context> { every { filesDir } returns tmp.newFolder() }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(
            HavenConfig(
                fipsPeers = listOf(mac),
                fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(mac, DeviceRole.MAC, sendNotes = sendNotes, sendMedia = sendMedia))),
            ),
        )
        return HomeVaultSender(context, config).apply {
            ownerHex = { "a".repeat(64) }
            ownerIsActive = { true }
        }
    }

    private fun HomeVaultSender.awaitWaiting(n: Int) {
        val deadline = System.currentTimeMillis() + 5_000
        while (state.value.waiting != n && System.currentTimeMillis() < deadline) Thread.sleep(20)
    }

    /** Checklist item 4: the Mac role was saved and read by nothing; only a home vault got sends. */
    @Test
    fun `a mac in my devices gets the owner's notes and media with no home vault`() = runBlocking {
        val s = macOnlySender()
        s.offerEvent("e1", "a".repeat(64), "{}")
        s.awaitWaiting(1)
        s.offerBlob("b".repeat(64), "image/png", byteArrayOf(1, 2, 3))
        s.drain()  // the mesh is off in a unit test: everything stays queued for the Mac
        assertEquals(2, s.state.value.waiting)
        assertEquals("The mesh is off", s.state.value.lastProblem)
    }

    @Test
    fun `a mac with Send notes and Send media off gets nothing`() = runBlocking {
        val s = macOnlySender(sendNotes = false, sendMedia = false)
        s.offerEvent("e1", "a".repeat(64), "{}")
        s.offerBlob("b".repeat(64), "image/png", byteArrayOf(1, 2, 3))
        s.drain()
        assertEquals(0, s.state.value.waiting)
    }

    /** Tron's repro (#1025): a drain before the config loads must not take a Mac's queue for a removed one. */
    @Test
    fun `a drain before the config is loaded keeps every mac queue`() = runBlocking {
        val dir = tmp.newFolder()
        val macDir = java.io.File(dir, "mesh_send_queue/$mac")
        HomeVaultQueue(macDir).addEvent("e1", "{}")
        val context = mockk<Context> { every { filesDir } returns dir }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(HavenConfig())  // defaults: not loaded
        val s = HomeVaultSender(context, config).apply {
            ownerHex = { "a".repeat(64) }
            ownerIsActive = { true }
        }
        s.drain()
        assertTrue(macDir.isDirectory)
        assertEquals(1, HomeVaultQueue(macDir).size)
    }

    @Test
    fun `nothing is offered while another account is active`() = runBlocking {
        val s = sender()
        s.ownerIsActive = { false }
        s.offerBlob("b".repeat(64), "image/png", byteArrayOf(1, 2, 3))
        s.drain()
        assertEquals(0, s.state.value.waiting)
        assertTrue(s.state.value.lastProblem == null)
    }
}
