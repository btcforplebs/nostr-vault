package com.nostrvault.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The profile picture's hold menu (Logen 2026-11-06): App settings and Mesh
 * settings on top, then a divider, then the accounts. The overlay
 * draws its items bottom-up, so the list starts with the bottom row.
 */
class AccountTabPickerItemsTest {
    private val a = "npub1aaaaaaaaaaaaaaaaaaaa"
    private val b = "npub1bbbbbbbbbbbbbbbbbbbb"

    /** What the overlay draws top to bottom. */
    private fun drawn(npubs: List<String>) = AccountTabPicker.items(npubs).reversed()

    @Test fun appSettingsThenMeshSettingsOnTopThenAccounts() {
        assertEquals(listOf(AccountTabPicker.APP_SETTINGS, AccountTabPicker.MESH_SETTINGS, b, a), drawn(listOf(a, b)))
    }

    @Test fun oneAccountStillHasBothSettingsRows() {
        assertEquals(listOf(AccountTabPicker.APP_SETTINGS, AccountTabPicker.MESH_SETTINGS, a), drawn(listOf(a)))
    }

    @Test fun settingsIdsAreNamedAndNeverAnNpub() {
        assertEquals("App settings", AccountTabPicker.settingsLabel(AccountTabPicker.APP_SETTINGS))
        assertEquals("Mesh settings", AccountTabPicker.settingsLabel(AccountTabPicker.MESH_SETTINGS))
        assertNull(AccountTabPicker.settingsLabel(a))
        listOf(AccountTabPicker.APP_SETTINGS, AccountTabPicker.MESH_SETTINGS).forEach { assert(!it.startsWith("npub1")) }
    }
}
