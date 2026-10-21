package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of iOS `MediaGalleryGrid.mediaContent`. */
class MediaEmptyStateTest {
    @Test
    fun `something to show means no empty state, even while loading`() {
        assertNull(mediaEmptyState(total = 5, shown = 2, isLoading = true))
        assertNull(mediaEmptyState(total = 5, shown = 5, isLoading = false))
    }

    @Test
    fun `nothing yet while scanning says loading`() {
        val state = mediaEmptyState(total = 0, shown = 0, isLoading = true)
        assertEquals(MediaEmptyState.LOADING, state)
        assertEquals("Loading media…", state!!.title)
        assertEquals("Scanning for uploads", state.detail)
    }

    @Test
    fun `a scan still running beats the filter hint, as on iOS`() {
        assertEquals(MediaEmptyState.LOADING, mediaEmptyState(total = 4, shown = 0, isLoading = true))
    }

    @Test
    fun `a filter hiding everything points at the filter`() {
        val state = mediaEmptyState(total = 4, shown = 0, isLoading = false)
        assertEquals(MediaEmptyState.FILTERED, state)
        assertEquals("No media found", state!!.title)
        assertEquals("Try changing your filter settings", state.detail)
    }

    @Test
    fun `no media at all does not blame the filter`() {
        val state = mediaEmptyState(total = 0, shown = 0, isLoading = false)
        assertEquals(MediaEmptyState.NONE, state)
        assertEquals("No media found", state!!.title)
        assertNull(state.detail)
    }
}
