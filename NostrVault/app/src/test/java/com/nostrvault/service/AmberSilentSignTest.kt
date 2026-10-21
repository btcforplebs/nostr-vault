package com.nostrvault.service

import android.content.ContentResolver
import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * A silent-only sign (the dashboard counts' relay AUTH, on every resume) never
 * opens Amber's approval screen: when Amber can't sign in the background, the
 * answer is null. A normal sign still falls back to the screen.
 */
class AmberSilentSignTest {
    private val owner = "a".repeat(64)

    // Amber's ContentProvider can't sign in the background: no grant yet.
    private val resolver = mockk<ContentResolver> {
        every { query(any(), any(), any(), any(), any()) } returns null
    }
    private val context = mockk<Context> { every { contentResolver } returns resolver }
    private val configStore = mockk<ConfigStore> {
        every { config } returns MutableStateFlow(HavenConfig(ownerNpub = owner, signingMode = "amber"))
    }
    // Restores the owner as its pubkey from config (amber mode, hex owner).
    private val amber = AmberSignerService(context, configStore)

    @Before
    fun setUp() {
        mockkObject(AmberResultBridge)
        coEvery { AmberResultBridge.launchAndAwait(any(), any()) } returns null
    }

    @After
    fun tearDown() {
        unmockkObject(AmberResultBridge)
    }

    @Test
    fun `silent only never launches the approval screen and gives null`() = runBlocking {
        assertNull(amber.signEvent("{}", asOwner = true, silentOnly = true))
        coVerify(exactly = 0) { AmberResultBridge.launchAndAwait(any(), any()) }
    }

    /** Every other caller behaves as before: no silent answer means the screen. */
    @Test
    fun `a normal sign still falls back to the approval screen`() = runBlocking {
        assertNull(amber.signEvent("{}", asOwner = true))
        coVerify(exactly = 1) { AmberResultBridge.launchAndAwait(any(), any()) }
    }
}
