package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.screens.profile.ProfileMediaAction.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The profile Media grid's long-press menu, in iOS MediaGridItem order. */
class ProfileMediaMenuTest {

    private val hash = "a".repeat(64)
    private val image = "https://blossom.example/$hash.jpg"

    @Test
    fun ownMediaGetsTheMenuWithoutReportOrBlock() {
        assertEquals(
            listOf(COPY_LINK, SAVE_TO_PHOTOS, SAVE_TO_VAULT, MARK_404),
            profileMediaMenu(image, inVault = false, needsMirror = false, is404 = false, moderationTarget = null),
        )
    }

    @Test
    fun someoneElsesMediaEndsWithReportThenBlock() {
        assertEquals(
            listOf(COPY_LINK, SAVE_TO_PHOTOS, SAVE_TO_VAULT, MARK_404, REPORT, BLOCK),
            profileMediaMenu(image, inVault = false, needsMirror = false, is404 = false, moderationTarget = "b".repeat(64)),
        )
    }

    @Test
    fun aFileInTheVaultOffersMirrorOnlyWhenAServerLacksIt() {
        assertEquals(
            listOf(COPY_LINK, SAVE_TO_PHOTOS, MIRROR_TO_BLOSSOM, UNMARK_404),
            profileMediaMenu(image, inVault = true, needsMirror = true, is404 = true, moderationTarget = null),
        )
        assertEquals(
            listOf(COPY_LINK, SAVE_TO_PHOTOS, MARK_404),
            profileMediaMenu(image, inVault = true, needsMirror = false, is404 = false, moderationTarget = null),
        )
    }

    @Test
    fun audioCannotGoToPhotos() {
        assertEquals(
            listOf(COPY_LINK, SAVE_TO_VAULT, MARK_404),
            profileMediaMenu("https://x.example/song.mp3", inVault = false, needsMirror = false, is404 = false, moderationTarget = null),
        )
    }

    @Test
    fun blossomHashComesFromTheFileName() {
        assertEquals(hash, blossomHashOf(image))
        assertEquals(hash, blossomHashOf("https://b.example/${hash.uppercase()}?x=1"))
        assertNull(blossomHashOf("https://b.example/photo.jpg"))
        assertNull(blossomHashOf("https://b.example/${"g".repeat(64)}.png"))
    }
}
