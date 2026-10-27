package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A profile's note cards must observe the liked set. Reading
 * `likedEventIds.value` once (`viewModel.isLiked(...)`) left the like button
 * unchanged after reacting until the list scrolled. Source-level because the
 * Compose tree needs a device, as in ImeInsetsGuardTest.
 */
class ProfileLikeStateGuardTest {
    private val src = File("src/main/java/com/nostrvault/ui/screens/profile/ProfileScreen.kt").readText()

    @Test
    fun likedSetIsCollectedAsState() {
        assertTrue(src.contains("viewModel.likedEventIds.collectAsState()"))
        assertTrue(src.contains("isLiked = note.effectiveEventId in likedIds"))
    }

    @Test
    fun cardsDoNotReadTheLikedSetOnce() {
        assertFalse(src.contains("isLiked = viewModel.isLiked("))
    }
}
