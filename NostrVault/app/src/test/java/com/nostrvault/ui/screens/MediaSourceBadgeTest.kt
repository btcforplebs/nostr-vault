package com.nostrvault.ui.screens

import com.nostrvault.service.MediaCacheService.MediaSource
import org.junit.Assert.assertEquals
import org.junit.Test

/** Port of iOS `SourceIndicatorView` and `MediaCacheService.MediaSource`. */
class MediaSourceBadgeTest {
    @Test
    fun `the vault copy wins over a cached one`() {
        assertEquals(MediaSource.BLOSSOM, viewerMediaSource(inVault = true, cached = true))
        assertEquals(MediaSource.BLOSSOM, viewerMediaSource(inVault = true, cached = false))
        assertEquals(MediaSource.CACHED, viewerMediaSource(inVault = false, cached = true))
        assertEquals(MediaSource.REMOTE, viewerMediaSource(inVault = false, cached = false))
    }

    @Test
    fun `badge text matches iOS`() {
        assertEquals("On phone", mediaSourceLabel(MediaSource.BLOSSOM))
        assertEquals("Temporary copy", mediaSourceLabel(MediaSource.CACHED))
        assertEquals("Link only", mediaSourceLabel(MediaSource.REMOTE))
    }

    @Test
    fun `unreachable servers are counted`() {
        assertEquals("Couldn't reach 1 server", unreachableServersText(1))
        assertEquals("Couldn't reach 3 servers", unreachableServersText(3))
    }
}
