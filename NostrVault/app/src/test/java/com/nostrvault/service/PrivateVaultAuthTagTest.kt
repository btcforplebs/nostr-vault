package com.nostrvault.service

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The /private AUTH must be signed with the vault's ServiceURL (wss://, see
 * VaultAuthTagTest), not the ws:// socket address, or the owner AUTH fails:
 * drafts never load back from the vault and Private copies can't be read or
 * cleared. Pinned at the source, as DMOwnRelayAndSelfCopyTest does for /chat
 * (signing needs the bridge, which plain unit tests can't load).
 */
class PrivateVaultAuthTagTest {
    private fun src(path: String) = File("src/main/java/com/nostrvault/$path").readText()

    private fun assertSignsVaultTag(path: String, fn: String) {
        val body = src(path).substringAfter(fn).substringBefore("\n    }")
        val tagLine = body.lines().first { "listOf(\"relay\"" in it }
        assertTrue("$path $fn: $tagLine", "vaultAuthRelayTag(url)" in tagLine)
    }

    @Test
    fun `drafts AUTH is signed with the vault auth tag`() =
        assertSignsVaultTag("service/DraftService.kt", "private suspend fun authenticate(")

    @Test
    fun `private copy AUTH is signed with the vault auth tag`() =
        assertSignsVaultTag("service/shareportal/PrivateCopyService.kt", "private suspend fun signAuth(")
}
