package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A Magic Paste of a link is stored in this vault by [BlossomService.mirrorUrlToLocal], which sends it nowhere else.
 * Like a picked or pasted image ([upload]), it then goes on the home vault's lane with a file note, so the owner's
 * other open Media tabs show it (2026-11-13: an iPhone paste never reached the iPad). Twin of Apple saveFromMediaTab.
 */
class PastedLinkHomeVaultTest {
    @get:Rule val tmp = TemporaryFolder()
    private val sha = "a".repeat(64)
    private val homeVault = mockk<HomeVaultSender>(relaxed = true)

    private fun service(): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1owner", relayDataDir = tmp.root.path))
        return BlossomService(configStore, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true), homeVault)
    }

    @Test fun aStoredPasteGoesToTheHomeVaultWithAFileNote() {
        val png = byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10) + ByteArray(32)
        val file = tmp.newFolder("blossom").resolve(sha).apply { writeBytes(png) }
        service().afterPastedLink(sha)
        verify { homeVault.offerBlob(sha, "image/png", file) }
        verify { homeVault.offerFileNote(sha, "image/png", png.size.toLong(), emptyList()) }
    }

    @Test fun nothingStoredSendsNothing() {
        service().afterPastedLink(sha)
        verify(exactly = 0) { homeVault.offerBlob(any(), any(), any<java.io.File>()) }
        verify(exactly = 0) { homeVault.offerFileNote(any(), any(), any(), any()) }
    }
}
