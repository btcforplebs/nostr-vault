package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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

    /**
     * Another app sets the clipboard and can open nostrvault://mediapaste, so
     * a pasted link must not reach this device's relay or the LAN (Android
     * review follow-up to #796, 2026-10-20). IP literals: no DNS in the test.
     */
    @Test fun aLinkToThisDeviceOrTheLanIsNotFetched() {
        assertFalse(pastedUrlIsPublic("http://127.0.0.1:4869/upload"))
        assertFalse(pastedUrlIsPublic("https://localhost:4869/a.jpg"))
        assertFalse(pastedUrlIsPublic("http://[::1]:4869/a.jpg"))
        assertFalse(pastedUrlIsPublic("http://0.0.0.0/a.jpg"))
        assertFalse(pastedUrlIsPublic("http://192.168.1.10/a.jpg"))
        assertFalse(pastedUrlIsPublic("http://10.44.0.53/a.jpg"))
        assertFalse(pastedUrlIsPublic("http://169.254.169.254/latest"))
        assertFalse(pastedUrlIsPublic("file:///data/data/com.nostrvault.app/files/nostrvault_config.json"))
        assertTrue(pastedUrlIsPublic("https://93.184.215.14/a.jpg"))
    }
}
