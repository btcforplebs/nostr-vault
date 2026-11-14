package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertEquals
import org.junit.Test

/** The inbox row's last-message line, as iOS ConversationRow writes it. */
class DMPreviewTextTest {

    @Test
    fun anEmptyMessageIsNamed() {
        assertEquals("No message content", dmPreviewText(null))
        assertEquals("No message content", dmPreviewText(""))
    }

    @Test
    fun aShortMessageIsShownWhole() {
        assertEquals("gm", dmPreviewText("gm"))
    }

    @Test
    fun aLongMessageIsCutAtSixtyWithAnEllipsis() {
        val long = "a".repeat(59) + " " + "b".repeat(20)
        assertEquals("a".repeat(59) + "…", dmPreviewText(long))
    }

    @Test
    fun aLockedPhotoIsNamedNotShownAsItsLink() {
        val link = com.nostrvault.service.DMFile.fileLink("https://a.example/f", "1".repeat(64), "2".repeat(24), null, "image/png")
        assertEquals("Photo", dmPreviewText(link))
    }
}
