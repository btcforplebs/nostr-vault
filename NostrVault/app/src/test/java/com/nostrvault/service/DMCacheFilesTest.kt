package com.nostrvault.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** DM caches under any old key shape are deleted; caches under a full hex pubkey are not. */
class DMCacheFilesTest {
    @Test
    fun `old key shapes are recognised`() {
        assertTrue(DMCacheFiles.isOldKeyCache("dm_cache_npub1sg6plzp.json"))
        assertTrue(DMCacheFiles.isOldKeyCache("dm_cache_${"a".repeat(12)}.json"))
        assertTrue(DMCacheFiles.isOldKeyCache("dm_cache_default.json"))
    }

    @Test
    fun `current and unrelated files are kept`() {
        assertFalse(DMCacheFiles.isOldKeyCache("dm_cache_${"a".repeat(64)}.json"))
        assertFalse(DMCacheFiles.isOldKeyCache("dm_unreadable_npub1sg6plzp.json"))
        assertFalse(DMCacheFiles.isOldKeyCache("other.json"))
    }
}
