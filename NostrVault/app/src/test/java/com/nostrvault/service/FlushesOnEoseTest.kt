package com.nostrvault.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FlushesOnEoseTest {
    @Test fun primaryEoseFlushes() {
        assertTrue(flushesOnEose("following-1", "following-1", loading = false, syncing = false))
    }

    @Test fun anyEoseFlushesWhileLoading() {
        assertTrue(flushesOnEose("feed-mentions", "following-1", loading = true, syncing = false))
        assertTrue(flushesOnEose("feed-zaps-in", "following-1", loading = false, syncing = true))
    }

    @Test fun laterAuxiliaryEoseDoesNotFlush() {
        assertFalse(flushesOnEose("feed-mentions", "following-1", loading = false, syncing = false))
        assertFalse(flushesOnEose("feed-reactions", "following-1", loading = false, syncing = false))
    }
}
