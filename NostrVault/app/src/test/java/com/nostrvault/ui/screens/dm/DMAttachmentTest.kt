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

    // Videos (Logen 2026-11-06), as iOS DMAttachmentTests.
    private val clip = "https://blossom.primal.net/0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9.mp4"

    @Test fun sentVideoSplitsBackIntoTextAndVideo() {
        val split = DMAttachment.split("watch\n$clip", withVideos = true)
        assertEquals("watch", split.text)
        assertEquals(listOf(clip), split.videos)
        assertEquals(emptyList<String>(), split.images)
    }

    @Test fun photosAndVideosBothShowOnce() {
        val split = DMAttachment.split("$photo\n$clip\n$clip", withVideos = true)
        assertEquals("", split.text)
        assertEquals(listOf(photo), split.images)
        assertEquals(listOf(clip), split.videos)
    }

    @Test fun videoLinksStayTextUnlessAsked() {
        val split = DMAttachment.split(clip)
        assertEquals(clip, split.text)
        assertEquals(emptyList<String>(), split.videos)
    }

    @Test fun videoLinkAddsTheExtensionOnlyWhenMissing() {
        assertEquals("https://cdn.example.com/abc123.mov", DMAttachment.videoLink("https://cdn.example.com/abc123", "mov"))
        assertEquals(clip, DMAttachment.videoLink(clip, "mov"))
        assertEquals("https://cdn.example.com/abc123", DMAttachment.videoLink("https://cdn.example.com/abc123", ""))
    }
}
