package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImportStartDateTest {
    @Test fun aStoredDateIsUtcMidnight() {
        assertEquals(1_704_067_200_000L, importDateToMillis("2024-01-01"))
    }

    @Test fun millisComeBackAsTheSameDate() {
        assertEquals("2024-01-01", importDateFromMillis(1_704_067_200_000L))
        assertEquals("2024-02-29", importDateFromMillis(importDateToMillis("2024-02-29")!!))
        // Any time of that UTC day is that date, not the next or previous one.
        assertEquals("2024-01-01", importDateFromMillis(1_704_067_200_000L + 86_399_999L))
    }

    @Test fun anUnreadableDateHasNoSelection() {
        assertNull(importDateToMillis(""))
        assertNull(importDateToMillis("not a date"))
        assertNull(importDateToMillis("2024-13-40"))
    }
}
