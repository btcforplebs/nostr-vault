package com.nostrvault.service

import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The signer retry, exercised through the real uploadAndMirror rather than
 * through a helper: the bug it fixes was that one failed signature killed a
 * whole image post, and a test of a retry helper in isolation would not have
 * caught that the upload path never called it.
 *
 * Only the signature is under test here. The uploads themselves fail (there is
 * no relay on localhost in a JVM test and no mirrors are configured), which is
 * fine — what these assert is how many times the signer was asked, and whether
 * the upload got past the auth step at all.
 */
class BlossomAuthRetryTest {

    private val sha = "a".repeat(64)

    init {
        // android.util.* is stubbed in JVM tests; Base64 returning null would
        // blow up the success path before the assertions.
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } returns "signed-auth-header"
    }

    private fun service(
        signer: NostrService,
        mirrors: List<String> = emptyList(),
    ): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            HavenConfig(ownerNpub = "npub1owner", blossomMirrors = mirrors)
        )
        return BlossomService(configStore, signer, mockk(relaxed = true), mockk(relaxed = true))
    }

    private fun signedEvent() = NostrEvent(
        id = "e".repeat(64),
        pubkey = "p".repeat(64),
        createdAt = 1_700_000_000L,
        kind = 24242,
        tags = listOf(listOf("t", "upload")),
        content = "Blossom upload aaaaaaaa",
        sig = "s".repeat(128),
    )

    @Test
    fun `a signature that fails once is retried and the upload continues`() = runTest {
        val signer = mockk<NostrService>(relaxed = true)
        var calls = 0
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } answers {
            calls++
            // Amber not resumed yet on the first ask, fine on the second.
            if (calls == 1) throw IllegalStateException("Amber signer failed") else signedEvent()
        }

        service(signer).uploadAndMirror(ByteArray(8), sha, "image/png")

        assertEquals("signer should have been asked twice", 2, calls)
    }

    @Test
    fun `the signer is asked three times at most`() = runTest {
        val signer = mockk<NostrService>(relaxed = true)
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } throws
            IllegalStateException("Amber signer failed")

        service(signer).uploadAndMirror(ByteArray(8), sha, "image/png")

        coVerify(exactly = 3) { signer.signEventAsync(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a declined prompt is not re-shown`() = runTest {
        val signer = mockk<NostrService>(relaxed = true)
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any()) } throws
            SignerRejectedException()

        service(signer).uploadAndMirror(ByteArray(8), sha, "image/png")

        // Exactly one ask: the user answered, and the answer was no.
        coVerify(exactly = 1) { signer.signEventAsync(any(), any(), any(), any(), any()) }
    }
}
