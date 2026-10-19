package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class NoteShareLinkTest {
    @Test fun sharesTheThreadLinkNotTheText() {
        assertEquals("https://mynostrspace.com/thread/nevent1abc", noteShareLink("nevent1abc", "note1xyz", "ff"))
    }

    @Test fun fallsBackToNote1ThenHex() {
        assertEquals("https://mynostrspace.com/thread/note1xyz", noteShareLink(null, "note1xyz", "ff"))
        assertEquals("https://mynostrspace.com/thread/ff", noteShareLink(null, null, "ff"))
    }
}
