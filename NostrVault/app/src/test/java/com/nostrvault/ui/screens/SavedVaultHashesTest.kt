package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SavedVaultHashesTest {
    private fun item(sha256: String, url: String) = BlossomMediaItem(
        sha256 = sha256, displayUrl = url, localFile = null, mimeType = null,
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test
    fun `saving one link-only item does not mark another as saved`() {
        val saved = SavedVaultHashes()
        val first = item("", "https://nostr.build/i/one.jpg")
        val second = item("", "https://nostr.build/i/two.jpg")
        saved.record(first, "a".repeat(64))
        assertEquals("a".repeat(64), saved.savedHash(first))
        assertNull(saved.savedHash(second))
    }

    @Test
    fun `an item with a hash is keyed by it`() {
        val saved = SavedVaultHashes()
        saved.record(item("b".repeat(64), "https://blossom.band/x.jpg"), "c".repeat(64))
        assertEquals("c".repeat(64), saved.savedHash(item("b".repeat(64), "https://other.example/y.jpg")))
        assertEquals("https://n.b/one.jpg", viewerItemKey(item("", "https://n.b/one.jpg")))
    }
}
