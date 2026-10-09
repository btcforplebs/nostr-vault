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
