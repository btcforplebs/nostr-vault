package com.nostrvault.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Old DM caches (truncated-npub key) are deleted; caches under the full hex key are not. */
class DMCacheFilesTest {
    @Test
    fun `old truncated-npub caches are recognised`() {
        assertTrue(DMCacheFiles.isTruncatedKeyCache("dm_cache_npub1sg6plzp.json"))
    }

    @Test
    fun `current and unrelated files are kept`() {
        assertFalse(DMCacheFiles.isTruncatedKeyCache("dm_cache_${"a".repeat(64)}.json"))
        assertFalse(DMCacheFiles.isTruncatedKeyCache("dm_cache_default.json"))
        assertFalse(DMCacheFiles.isTruncatedKeyCache("dm_unreadable_npub1sg6plzp.json"))
        assertFalse(DMCacheFiles.isTruncatedKeyCache("dm_cache_npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m.json"))
    }
}
