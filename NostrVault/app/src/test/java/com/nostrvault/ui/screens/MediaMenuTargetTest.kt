package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class MediaMenuTargetTest {
    private fun item(sha: String) = BlossomMediaItem(
        sha256 = sha, displayUrl = "https://x/$sha", localFile = null, mimeType = "image/jpeg",
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test
    fun fileLandingAheadKeepsTheMenuOnTheLongPressedFile() {
        val before = listOf(item("aa"), item("bb"), item("cc"))
        val target = before[1].sha256 // long-press on "bb"
        val after = listOf(item("new")) + before // a file lands at the top
        assertEquals(listOf("bb"), after.filter { isMenuTarget(target, it) }.map { it.sha256 })
    }

    @Test
    fun deletedFileLeavesNoMenuOpen() {
        val after = listOf(item("aa"), item("cc"))
        assertFalse(after.any { isMenuTarget("bb", it) })
        assertFalse(after.any { isMenuTarget(null, it) })
    }

    @Test
    fun caseOfTheHashDoesNotMatter() {
        assertEquals(true, isMenuTarget("AB", item("ab")))
    }

    @Test
    fun targetClearsWhenItsFileLeavesTheList() {
        // Deleted while its menu is open: the target goes, so the menu cannot
        // reopen by itself when the same file comes back.
        assertEquals(null, menuTargetAfter("bb", listOf(item("aa"), item("cc"))))
        assertEquals("BB", menuTargetAfter("BB", listOf(item("aa"), item("bb"))))
        assertEquals(null, menuTargetAfter(null, listOf(item("aa"))))
    }
}
