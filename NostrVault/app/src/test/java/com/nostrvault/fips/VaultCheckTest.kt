package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** iOS a652aeb7: the "already on the vault" HEAD is signed, or the door answers 404 and the photo goes again. */
class VaultCheckTest {
    private val sha = "a".repeat(64)

    @Test
    fun `the check is the owner's get for that blob, five minutes`() {
        assertEquals(
            listOf(listOf("t", "get"), listOf("x", sha), listOf("expiration", "1300")),
            VaultCheck.authTags(sha, nowSeconds = 1000),
        )
    }

    @Test
    fun `the HEAD carries the auth, and goes unsigned only when signing failed`() {
        val signed = VaultCheck.request("http://127.0.0.1:4000", sha, "QUJD")
        assertEquals("HEAD", signed.method)
        assertEquals("http://127.0.0.1:4000/$sha", signed.url.toString())
        assertEquals("Nostr QUJD", signed.header("Authorization"))
        assertNull(VaultCheck.request("http://127.0.0.1:4000", sha, null).header("Authorization"))
    }

    /** Both checks in HomeVaultSender go through VaultCheck: no bare HEAD left to send unsigned. */
    @Test
    fun `the sender has no unsigned HEAD`() {
        val src = File("src/main/java/com/nostrvault/fips/HomeVaultSender.kt").readText()
        assertTrue("a bare .head() would skip the signed get", !src.contains(".head()"))
        assertEquals(2, Regex("""VaultCheck\.request\(""").findAll(src).count())
    }
}
