package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The +N / -N pill next to a backup, as iOS deltaLabel. */
class FollowingDeltaLabelTest {

    @Test
    fun `more follows now shows plus`() {
        assertEquals("+12", followingDeltaLabel(snapshotCount = 988, currentCount = 1000))
    }

    @Test
    fun `fewer follows now shows minus`() {
        assertEquals("-3", followingDeltaLabel(snapshotCount = 1003, currentCount = 1000))
    }

    @Test
    fun `same count shows nothing`() {
        assertNull(followingDeltaLabel(snapshotCount = 1000, currentCount = 1000))
    }
}
