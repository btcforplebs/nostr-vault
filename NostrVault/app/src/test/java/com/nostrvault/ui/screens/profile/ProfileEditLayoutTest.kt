package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Edit Profile form is laid out as iOS ProfileEditView, and still edits the same eight keys. */
class ProfileEditLayoutTest {
    private val groups = ProfileEditLayout.groups

    @Test
    fun groupsAreInIosOrder() {
        assertEquals(listOf("IDENTITY", "BIO", "MEDIA", "LIGHTNING"), groups.map { it.title })
    }

    @Test
    fun fieldsAreInIosOrderWithIosLabels() {
        assertEquals(
            listOf(
                listOf("Display Name", "Username", "NIP-05"),
                listOf("About"),
                listOf("Picture URL", "Banner URL", "Website"),
                listOf("Address (lud16)"),
            ),
            groups.map { g -> g.fields.map { it.label } },
        )
    }

    @Test
    fun placeholdersMatchIos() {
        val byKey = groups.flatMap { it.fields }.associate { it.key to it.placeholder }
        assertEquals("Satoshi Nakamoto", byKey[ProfileMetadataMerge.DISPLAY_NAME])
        assertEquals("satoshi", byKey[ProfileMetadataMerge.NAME])
        assertEquals("you@domain.com", byKey[ProfileMetadataMerge.NIP05])
        assertEquals("Tell people about yourself…", byKey[ProfileMetadataMerge.ABOUT])
        assertEquals("https://…", byKey[ProfileMetadataMerge.PICTURE])
        assertEquals("https://…", byKey[ProfileMetadataMerge.BANNER])
        assertEquals("yourdomain.com", byKey[ProfileMetadataMerge.WEBSITE])
        assertEquals("you@walletofsatoshi.com", byKey[ProfileMetadataMerge.LUD16])
    }

    @Test
    fun everySavedKeyHasExactlyOneField() {
        val keys = groups.flatMap { g -> g.fields.map { it.key } }
        assertEquals(keys.size, keys.toSet().size)
        assertEquals(
            setOf(
                ProfileMetadataMerge.DISPLAY_NAME, ProfileMetadataMerge.NAME, ProfileMetadataMerge.ABOUT,
                ProfileMetadataMerge.PICTURE, ProfileMetadataMerge.BANNER, ProfileMetadataMerge.NIP05,
                ProfileMetadataMerge.LUD16, ProfileMetadataMerge.WEBSITE,
            ),
            keys.toSet(),
        )
    }

    @Test
    fun onlyAboutIsMultilineAndPhotoButtonsSitInMedia() {
        assertEquals(listOf(ProfileMetadataMerge.ABOUT), groups.flatMap { it.fields }.filter { it.multiline }.map { it.key })
        assertEquals(listOf("MEDIA"), groups.filter { it.photoPickers }.map { it.title })
    }

    @Test
    fun linksAndAddressesGetPlainKeyboards() {
        val byKey = groups.flatMap { it.fields }.associateBy { it.key }
        for (key in listOf(ProfileMetadataMerge.PICTURE, ProfileMetadataMerge.BANNER, ProfileMetadataMerge.WEBSITE)) {
            assertEquals(ProfileEditKeyboard.URL, byKey.getValue(key).keyboard)
        }
        for (key in listOf(ProfileMetadataMerge.NIP05, ProfileMetadataMerge.LUD16)) {
            assertEquals(ProfileEditKeyboard.EMAIL, byKey.getValue(key).keyboard)
        }
        assertTrue(byKey.getValue(ProfileMetadataMerge.DISPLAY_NAME).keyboard == ProfileEditKeyboard.DEFAULT)
        assertFalse(byKey.getValue(ProfileMetadataMerge.NAME).multiline)
    }
}
