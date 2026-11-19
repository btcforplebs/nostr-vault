package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** NV_MESSAGES_UX_CHECK 2026-11-18, B5 and B8 on Android. */
class DMThreadBatchTest {
    @Test fun `the keyboard opening at the end scrolls by what it covered`() {
        assertEquals(700f, DMKeyboardFollow.scrollFor(before = 1800, after = 1100, wasAtEnd = true))
    }

    @Test fun `reading older messages, or the list growing, moves nothing`() {
        assertNull(DMKeyboardFollow.scrollFor(1800, 1100, wasAtEnd = false))
        assertNull("the keyboard closing", DMKeyboardFollow.scrollFor(1100, 1800, wasAtEnd = true))
        assertNull("the first layout", DMKeyboardFollow.scrollFor(0, 1800, wasAtEnd = true))
    }

    @Test fun `at the end means the last message ends on screen`() {
        assertTrue(DMKeyboardFollow.atEnd(lastVisibleIndex = 9, total = 10, lastItemEnd = 1800, viewportEnd = 1800))
        assertTrue("a few pixels of slack", DMKeyboardFollow.atEnd(9, 10, 1803, 1800))
        assertFalse("its bottom is below the edge", DMKeyboardFollow.atEnd(9, 10, 1900, 1800))
        assertFalse(DMKeyboardFollow.atEnd(8, 10, 1800, 1800))
        assertTrue("an empty chat", DMKeyboardFollow.atEnd(null, 0, 0, 1800))
    }

    @Test fun `a send that fails after you left says so, naming who and what`() {
        assertEquals(
            "Your photo or video to Alice didn't send. Couldn't upload that photo.",
            DMSendFailure.leftChatFailure("Alice", hadMedia = true, error = DMPhotoUploadException()),
        )
        assertEquals(
            "Your message to Bob didn't send. The message could not be sent.",
            DMSendFailure.leftChatFailure("Bob", hadMedia = false, error = RuntimeException()),
        )
    }
}
