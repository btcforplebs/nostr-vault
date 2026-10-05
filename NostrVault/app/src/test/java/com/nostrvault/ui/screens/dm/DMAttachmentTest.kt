package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertEquals
import org.junit.Test

/** A DM photo is its Blossom URL in an ordinary message, shown as the photo (iOS DMAttachmentTests, #288). */
class DMAttachmentTest {
    private val photo = "https://blossom.primal.net/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08.jpg"

    @Test fun sentMessageSplitsBackIntoTextAndPhoto() {
        val split = DMAttachment.split("look\n$photo")
        assertEquals("look", split.text)
        assertEquals(listOf(photo), split.images)
    }

    @Test fun photoOnlyMessageHasNoText() {
        val split = DMAttachment.split(photo)
        assertEquals("", split.text)
        assertEquals(listOf(photo), split.images)
    }

    @Test fun photoInsideASentenceKeepsTheWordsAroundIt() {
        val split = DMAttachment.split("before $photo after")
        assertEquals("before after", split.text)
        assertEquals(listOf(photo), split.images)
    }

    @Test fun gifAndQueryStringCount() {
        val gif = "https://media.tenor.com/abc/cat.GIF?width=200"
        assertEquals(listOf(gif), DMAttachment.split(gif).images)
    }

    @Test fun repeatsShowOnce() {
        assertEquals(listOf(photo), DMAttachment.split("$photo\n$photo").images)
    }

    @Test fun otherLinksStayAsText() {
        for (content in listOf(
            "https://example.com/page",
            "https://example.com/clip.mp4",
            "ftp://example.com/a.jpg",
            "file:///private/a.jpg",
            "see example.com/a.jpg",
        )) {
            val split = DMAttachment.split(content)
            assertEquals(content, emptyList<String>(), split.images)
            assertEquals(content, content, split.text)
        }
    }

    @Test fun plainTextIsUntouched() {
        val text = "  two\n\nlines  "
        assertEquals(text, DMAttachment.split(text).text)
    }
}
