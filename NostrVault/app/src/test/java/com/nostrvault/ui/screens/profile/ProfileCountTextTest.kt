package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileCountTextTest {
    @Test fun shortForms() {
        assertEquals("639", ProfileCountText.short(639))
        assertEquals("1.0k", ProfileCountText.short(1_000))
        assertEquals("2.3M", ProfileCountText.short(2_300_000))
    }

    @Test fun plusWhileMoreMayCome() {
        assertEquals("48+", ProfileCountText.of(48, hasMore = true))
        assertEquals("48", ProfileCountText.of(48, hasMore = false))
    }

    @Test fun dashWhenNothingLoadedYet() {
        assertEquals("—", ProfileCountText.of(0, hasMore = true))
        assertEquals("0", ProfileCountText.of(0, hasMore = false))
    }
}
