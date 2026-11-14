package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LockedUploadServersTest {
    private val x = "ab".repeat(32)

    @Test
    fun `only servers the other person can reach, the fallback once`() {
        assertEquals(
            listOf("https://blossom.primal.net"),
            lockedUploadServers(listOf("http://127.0.0.1:4848", "http://192.168.1.5:3334", "https://blossom.primal.net/", "https://nostr.download")),
        )
    }

    @Test
    fun `a link must name the ciphertext's hash`() {
        assertTrue(namesHash("https://nostr.download/$x", x))
        assertTrue(namesHash("https://nostr.download/$x.bin", x))
        assertFalse(namesHash("https://image.nostr.build/${"cd".repeat(32)}.jpg", x))
        assertFalse(namesHash("not a url", x))
    }
}
