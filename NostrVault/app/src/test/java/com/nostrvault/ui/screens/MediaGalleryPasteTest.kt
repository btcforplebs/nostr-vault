package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Paste on the Media tab downloads only an http(s) link, as iOS does. */
class MediaGalleryPasteTest {
    @Test fun httpsLinkIsKept() {
        assertEquals("https://m.example/a.jpg", pastedMediaUrl("  https://m.example/a.jpg\n"))
        assertEquals("http://m.example/v.mp4?x=1", pastedMediaUrl("http://m.example/v.mp4?x=1"))
    }

    @Test fun otherTextIsRejected() {
        assertNull(pastedMediaUrl(""))
        assertNull(pastedMediaUrl("hello world"))
        assertNull(pastedMediaUrl("ftp://m.example/a.jpg"))
        assertNull(pastedMediaUrl("nostr:npub1abc"))
        assertNull(pastedMediaUrl("https://"))
        assertNull(pastedMediaUrl("https://m.example/a.jpg and more"))
    }
}
