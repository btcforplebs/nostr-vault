package com.nostrvault.service

import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.PostingAccount
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
 * One rule everywhere (Logen 2026-11-01): a note's media is signed by the
 * account the note posts as, through that account's own signer, never by the
 * owner on its behalf. Owner signing stays for everything else (vault, backup).
 */
class BlossomPostingAccountAuthTest {
    private val sha = "c".repeat(64)
    private val alt = PostingAccount.Lock(npub = "npub1alt", hex = "a".repeat(64))
    private val signer = mockk<NostrService>(relaxed = true)

    init {
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } returns "signed-auth-header"
    }

    private fun service(): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1owner"))
        every { signer.ownerHexPubkey } returns "o".repeat(64)
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            NostrEvent("e".repeat(64), "p".repeat(64), 1_700_000_000L, 24242, emptyList(), "Blossom", "s".repeat(128))
        return BlossomService(configStore, signer, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true))
    }

    @Test fun anUploadForAnotherAccountIsSignedByThatAccount() = runTest {
        assertEquals("signed-auth-header", service().createAuthHeader("upload", sha, signAs = alt))
        coVerify(exactly = 1) { signer.signEventAsync(24242, any(), any(), any(), forceOwner = false, lockedTo = alt, any(), any()) }
        coVerify(exactly = 0) { signer.signEventAsync(any(), any(), any(), any(), forceOwner = true, any(), any(), any()) }
    }

    @Test fun aDeleteForAnotherAccountIsSignedByThatAccount() = runTest {
        service().createDeleteAuthHeader(sha, "https://m.example/$sha", signAs = alt)
        coVerify(exactly = 1) { signer.signEventAsync(24242, any(), any(), any(), forceOwner = false, lockedTo = alt, any(), any()) }
    }

    /** Vault, backup and other owner uploads pass no account: still the owner, as before. */
    @Test fun withNoAccountTheOwnerSigns() = runTest {
        service().createAuthHeader("upload", sha)
        coVerify(exactly = 1) { signer.signEventAsync(24242, any(), any(), any(), forceOwner = true, lockedTo = null, any(), any()) }
    }

    /** Switched away mid-upload: nothing is signed as the new account, and no retry prompts. */
    @Test fun anAccountChangeSignsNothing() = runTest {
        val service = service()
        coEvery { signer.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } throws PostingAccount.AccountChangedException()
        assertEquals("", service.createAuthHeader("upload", sha, signAs = alt))
        coVerify(exactly = 1) { signer.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) }
    }
}
