package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Media tab sort orders, ported from iOS MediaSortOption. */
class MediaSortOptionTest {
    private fun item(id: Char, mime: String?, time: Long, local: Boolean = false) = BlossomMediaItem(
        sha256 = id.toString().repeat(64), displayUrl = "https://m.example/$id", localFile = null,
        mimeType = mime, size = null, uploaded = time, lastModified = null, isLocal = local,
    )

    private val photoOld = item('a', "image/png", 100)
    private val videoNew = item('b', "video/mp4", 400, local = true)
    private val gifMid = item('c', "image/gif", 300)
    private val photoNew = item('d', "image/jpeg", 200, local = true)
    private val all = listOf(photoOld, videoNew, gifMid, photoNew)

    private fun ids(items: List<BlossomMediaItem>) = items.joinToString("") { it.sha256.take(1) }

    @Test fun byDate() {
        assertEquals("bcda", ids(MediaSortOption.NEWEST_FIRST.sorted(all)))
        assertEquals("adcb", ids(MediaSortOption.OLDEST_FIRST.sorted(all)))
    }

    @Test fun byTypeThenNewest() {
        // Photos (newest first), then GIFs, then videos.
        assertEquals("dacb", ids(MediaSortOption.MEDIA_TYPE.sorted(all)))
    }

    @Test fun onRelayFirstThenNewest() {
        assertEquals("bdca", ids(MediaSortOption.ON_RELAY_FIRST.sorted(all)))
    }

    @Test fun storedKeyRoundTripsAndDefaults() {
        for (option in MediaSortOption.entries) assertEquals(option, MediaSortOption.fromKey(option.key))
        assertEquals(MediaSortOption.NEWEST_FIRST, MediaSortOption.fromKey(null))
        assertEquals(MediaSortOption.NEWEST_FIRST, MediaSortOption.fromKey("bogus"))
        // Same raw values iOS stores.
        assertEquals("onRelayFirst", MediaSortOption.ON_RELAY_FIRST.key)
    }

    @Test fun onlyDateSortsGroupByDate() {
        assertTrue(MediaSortOption.NEWEST_FIRST.groupsByDate)
        assertTrue(MediaSortOption.OLDEST_FIRST.groupsByDate)
        assertFalse(MediaSortOption.MEDIA_TYPE.groupsByDate)
        assertFalse(MediaSortOption.ON_RELAY_FIRST.groupsByDate)
    }
}
