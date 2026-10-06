package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareableMediaUrlTest {
    @Test fun publicLinksCopyLocalOnesDoNot() {
        assertTrue(isShareableMediaUrl("https://image.nostr.build/abc.jpg"))
        assertTrue(isShareableMediaUrl("https://blossom.primal.net/0123abcd"))
        assertFalse(isShareableMediaUrl("http://127.0.0.1:3355/abc.jpg"))
        assertFalse(isShareableMediaUrl("http://LOCALHOST:3355/abc"))
        assertFalse(isShareableMediaUrl("http://0.0.0.0/abc"))
        assertFalse(isShareableMediaUrl("not a url"))
    }
}
