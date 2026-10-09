package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of iOS `MediaCacheService.blossomHash(in:)`: only a last path part that is the hash names the blob. */
class BlossomHashInUrlTest {
    private val hash = "0123456789abcdef".repeat(4)

    @Test
    fun `the hash as the last path part, with or without an extension`() {
        assertEquals(hash, blossomHashInUrl("https://blossom.band/$hash"))
        assertEquals(hash, blossomHashInUrl("https://blossom.band/$hash.jpg"))
        assertEquals(hash, blossomHashInUrl("https://cdn.example/${hash.uppercase()}.PNG?w=400#x"))
    }

    @Test
    fun `a server-chosen URL does not name the blob`() {
        assertNull(blossomHashInUrl("https://nostr.build/i/abc123.jpg"))
        assertNull(blossomHashInUrl("https://cdn.example/$hash/thumb.jpg"))
        assertNull(blossomHashInUrl("https://cdn.example/x$hash.jpg"))
        assertNull(blossomHashInUrl("https://cdn.example/${hash.take(63)}.jpg"))
        assertNull(blossomHashInUrl("https://cdn.example/$hash.tar.gz"))
    }
}
