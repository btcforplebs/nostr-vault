package com.nostrvault.service

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Import media into this device's own vault: a keyless vault (npub only) goes
 * in-process and never asks a signer; a keyed vault signs once, as before.
 */
class OwnVaultAuthTest {
    @Test
    fun `a keyless vault never asks the signer`() = runBlocking {
        var asked = 0
        val auth = OwnVaultAuth.of(keyless = true) { asked++; "signed" }
        assertEquals(OwnVaultAuth.Keyless, auth)
        assertEquals(0, asked)
    }

    @Test
    fun `a keyed vault signs one header, unchanged`() = runBlocking {
        var asked = 0
        val auth = OwnVaultAuth.of(keyless = false) { asked++; "base64header" }
        assertEquals(OwnVaultAuth.Signed("base64header"), auth)
        assertEquals(1, asked)
    }

    @Test
    fun `a keyed vault whose signer gives nothing stops, as before`() = runBlocking {
        assertNull(OwnVaultAuth.of(keyless = false) { "" })
    }

    @Test
    fun `the keyless path hands the vault the file's bytes and hash, then deletes the temp file`() {
        val dir = Files.createTempDirectory("ownvault").toFile()
        try {
            var seen: Triple<String, String, String>? = null
            var bytes: ByteArray? = null
            val ok = OwnVaultFile.store("photo".toByteArray(), "a".repeat(64), "image/jpeg", dir) { path, sha, type ->
                seen = Triple(path, sha, type)
                bytes = File(path).readBytes()
                true
            }
            assertTrue(ok)
            assertEquals("a".repeat(64), seen!!.second)
            assertEquals("image/jpeg", seen!!.third)
            assertEquals("photo", String(bytes!!))
            assertFalse("temp file deleted", File(seen!!.first).exists())

            // Refused, or thrown: still no temp file left.
            assertFalse(OwnVaultFile.store("x".toByteArray(), "b".repeat(64), "image/png", dir) { _, _, _ -> false })
            runCatching { OwnVaultFile.store("y".toByteArray(), "c".repeat(64), "image/png", dir) { _, _, _ -> error("boom") } }
            assertEquals(0, dir.listFiles()!!.size)
        } finally {
            dir.deleteRecursively()
        }
    }
}
