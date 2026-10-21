package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class ProfileDiskCacheTest {
    private fun profile(pubkey: String, name: String, createdAt: Long?) =
        FeedProfile(pubkey = pubkey, name = name, createdAt = createdAt)

    @Test
    fun `profiles fetched before the cache is read survive the read`() {
        val disk = mapOf("a" to profile("a", "disk-a", 100))
        val live = mapOf("b" to profile("b", "live-b", 50))

        val merged = mergeDiskProfiles(disk, live)

        assertEquals(setOf("a", "b"), merged.keys)
        assertEquals("live-b", merged.getValue("b").name)
    }

    @Test
    fun `the newer kind 0 wins either way`() {
        val disk = mapOf(
            "a" to profile("a", "disk-a", 200),
            "b" to profile("b", "disk-b", 100),
            "c" to profile("c", "disk-c", null),
        )
        val live = mapOf(
            "a" to profile("a", "live-a", 150),
            "b" to profile("b", "live-b", 100),
            "c" to profile("c", "live-c", 10),
        )

        val merged = mergeDiskProfiles(disk, live)

        assertEquals("disk-a", merged.getValue("a").name)
        assertEquals("live-b", merged.getValue("b").name)
        assertEquals("live-c", merged.getValue("c").name)
    }

    @Test
    fun `nothing fetched yet keeps the disk map`() {
        val disk = mapOf("a" to profile("a", "disk-a", 100))
        assertSame(disk, mergeDiskProfiles(disk, emptyMap()))
    }

    @Test
    fun `a save inside the throttle window is deferred, not dropped`() {
        val window = NostrService.PROFILE_SAVE_THROTTLE_MS
        assertEquals(10_000L, nextProfileSaveAt(now = 10_000L, lastSaveAt = 0L))
        assertEquals(10_000L + window, nextProfileSaveAt(now = 11_000L, lastSaveAt = 10_000L))
        assertEquals(20_000L, nextProfileSaveAt(now = 20_000L, lastSaveAt = 10_000L))
    }
}
