package com.nostrvault.ui.screens

import com.nostrvault.ui.screens.dm.DMAttachment
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** The link the live chat sends for a picked Blossom file (#307 review). */
class BlossomShareLinkTest {
    private val sha = "a".repeat(64)

    private fun item(url: String, mime: String?, file: File? = null) = BlossomMediaItem(
        sha256 = sha, displayUrl = url, localFile = file, mimeType = mime,
        size = null, uploaded = null, lastModified = null, isLocal = file != null,
    )

    @Test
    fun bareMirrorUrlGetsTheExtensionAndShowsAsAPicture() {
        val link = blossomShareLink(item("https://blossom.example.com/$sha", "image/png"))
        assertEquals("https://blossom.example.com/$sha.png", link)
        assertEquals(listOf(link), DMAttachment.split(link).images)
    }

    @Test
    fun localFileNameGivesTheTypeWhenTheServerDidNot() {
        val link = blossomShareLink(item("https://blossom.example.com/$sha", "image", File("/x/$sha.webp")))
        assertEquals("https://blossom.example.com/$sha.webp", link)
    }

    @Test
    fun aLinkWithAnExtensionIsLeftAlone() {
        val url = "http://127.0.0.1:3355/$sha.jpg"
        assertEquals(url, blossomShareLink(item(url, "image/png")))
    }

    @Test
    fun unknownTypeFallsBackByKindAndQueryStays() {
        assertEquals("https://b.example/$sha.mp4?x=1", blossomShareLink(item("https://b.example/$sha?x=1", "video")))
        assertEquals("https://b.example/$sha.jpg", blossomShareLink(item("https://b.example/$sha", null)))
    }
}
