package com.nostrvault.service

import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * A post may only wait in the queue if its blob is really on this device. In a
 * JVM test nothing listens on the local relay port, so the local save fails;
 * the outcome must then be "not saved", never "saved on device" or "no
 * outside server" (which both imply the photo is safe here).
 */
class BlossomPostOutcomeTest {

    private val sha = "c".repeat(64)

    init {
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } returns "signed-auth-header"
    }

    private fun service(signer: NostrService): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            // Port 9 (discard) — nothing answers, so the local save fails fast.
            HavenConfig(ownerNpub = "npub1owner", blossomMirrors = emptyList(), relayPort = 9)
        )
        return BlossomService(configStore, signer, mockk(relaxed = true), mockk(relaxed = true))
    }

    private fun signer(): NostrService = mockk<NostrService>(relaxed = true).also {
        coEvery { it.signEventAsync(any(), any(), any(), any(), any()) } returns NostrEvent(
            id = "e".repeat(64), pubkey = "p".repeat(64), createdAt = 1_700_000_000L,
            kind = 24242, tags = listOf(listOf("t", "upload")), content = "Blossom upload", sig = "s".repeat(128),
        )
    }

    @Test
    fun `a failed local save with no outside server is not saved on device`() = runTest {
        val file = File.createTempFile("outcome", ".bin").apply { writeBytes(ByteArray(8)); deleteOnExit() }
        val outcome = service(signer()).uploadForPost(file, sha, "image/png")
        assertEquals(BlossomService.PostUploadOutcome.NotSavedOnDevice, outcome)
    }

    @Test
    fun `an unavailable signer is not saved on device`() = runTest {
        val signer = mockk<NostrService>(relaxed = true)
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } throws SignerRejectedException()
        val file = File.createTempFile("outcome", ".bin").apply { writeBytes(ByteArray(8)); deleteOnExit() }
        assertEquals(BlossomService.PostUploadOutcome.NotSavedOnDevice, service(signer).uploadForPost(file, sha, "image/png"))
    }
}
