package com.nostrvault.ui.screens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposeMediaDropTest {
    @Test fun photosAndVideosAreTaken() {
        assertTrue(carriesDroppableMedia(listOf("image/jpeg")))
        assertTrue(carriesDroppableMedia(listOf("text/plain", "video/mp4")))
    }

    @Test fun textAndFilesAreLeftAlone() {
        assertFalse(carriesDroppableMedia(listOf("text/plain")))
        assertFalse(carriesDroppableMedia(listOf("application/pdf")))
        assertFalse(carriesDroppableMedia(emptyList()))
    }
}
