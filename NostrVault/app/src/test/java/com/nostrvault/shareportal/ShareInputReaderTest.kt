package com.nostrvault.shareportal

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareInputReaderTest {
    // The Intent action constants are compile-time strings, so no Android runtime is needed.
    @Test fun chromeUrlLandsInUrlWithTheSubjectAsTitle() {
        val i = ShareInputReader.textInput(Intent.ACTION_SEND, " https://e.com/a ", "A page", null)
        assertEquals("https://e.com/a", i.url)
        assertEquals("A page", i.title)
        assertNull(i.text)
    }

    @Test fun textWithAUrlInsideStaysText() {
        val i = ShareInputReader.textInput(Intent.ACTION_SEND, "Read https://e.com/a now", null, null)
        assertNull(i.url)
        assertEquals("Read https://e.com/a now", i.text)
    }

    @Test fun processTextIsASelectionWithNoUrl() {
        val i = ShareInputReader.textInput(Intent.ACTION_PROCESS_TEXT, "ignored", null, "picked words")
        assertEquals("picked words", i.selection)
        assertNull(i.url); assertNull(i.text)
    }

    @Test fun otherActionsReadNothing() {
        assertEquals(ShareInput(), ShareInputReader.textInput(Intent.ACTION_VIEW, "x", "y", "z"))
    }

    @Test fun textIsCapped() {
        val i = ShareInputReader.textInput(Intent.ACTION_SEND, "x".repeat(200_000), "t".repeat(5_000), null)
        assertEquals(ShareIntent.MAX_TEXT, i.text!!.length)
        assertEquals(ShareIntent.MAX_TITLE, i.title!!.length)
        val p = ShareInputReader.textInput(Intent.ACTION_PROCESS_TEXT, null, null, "s".repeat(20_000))
        assertEquals(ShareIntent.MAX_SELECTION, p.selection!!.length)
    }

    @Test fun fileNamesAreRebuiltSafe() {
        assertEquals("passwd", ShareInputReader.safeFileName("../../etc/passwd", null))
        assertEquals("evil.pdf", ShareInputReader.safeFileName("a\\b\\..\\evil.pdf", null))
        assertEquals("hidden", ShareInputReader.safeFileName(".hidden", null))
        assertEquals("shared.pdf", ShareInputReader.safeFileName("..", "application/pdf"))
        assertEquals("shared.ics", ShareInputReader.safeFileName(null, "text/calendar"))
        val long = ShareInputReader.safeFileName("n".repeat(300) + ".pdf", null)
        assertTrue(long.length <= 100 && long.endsWith(".pdf"))
        assertTrue(ShareIntent.isValidFileName(long))
    }
}
