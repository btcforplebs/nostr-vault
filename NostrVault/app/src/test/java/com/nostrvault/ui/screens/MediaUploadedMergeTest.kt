package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Merging one blob listed by several servers keeps its oldest upload date. */
class MediaUploadedMergeTest {
    private fun merge(dates: List<Long?>): Long? =
        dates.fold(null as Long?) { kept, next -> oldestUploaded(kept, next) }

    @Test
    fun keepsTheOldestDate() {
        assertEquals(100L, oldestUploaded(300L, 100L))
        assertEquals(100L, oldestUploaded(100L, 300L))
    }

    @Test
    fun serverOrderSwappedGivesTheSameDate() {
        val servers = listOf<Long?>(500L, null, 200L, 900L)
        assertEquals(200L, merge(servers))
        assertEquals(merge(servers), merge(servers.reversed()))
        assertEquals(merge(servers), merge(listOf(900L, 200L, null, 500L)))
    }

    @Test
    fun aMissingDateNeverWins() {
        assertEquals(400L, oldestUploaded(null, 400L))
        assertEquals(400L, oldestUploaded(400L, null))
        assertNull(oldestUploaded(null, null))
    }
}
