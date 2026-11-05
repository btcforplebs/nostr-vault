package com.nostrvault.ui.screens.settings

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import io.mockk.every
import io.mockk.mockk
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Adding an npub that is already the owner or an added account as view-only
 * leaves it alone: it used to set that account's signing mode to "local",
 * which put an Amber or bunker account on a key it does not have (bug hunt
 * 2026-11-05 #5).
 */
class AddViewOnlyTest {
    private val filesDir: File = Files.createTempDirectory("add-view-only").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@AddViewOnlyTest.filesDir }

    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val second = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"
    private val fresh = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    private val store = ConfigStore(context).apply {
        reload()
        update {
            it.copy(
                ownerNpub = owner,
                accountNpubs = listOf(second),
                accountSigningModes = mapOf(owner to "amber", second to "nip46"),
            )
        }
    }
    private val viewModel = AccountSettingsViewModel(store, mockk(relaxed = true), mockk(relaxed = true))

    @Test
    fun `the owner on Amber keeps Amber`() {
        assertEquals(ALREADY_ADDED, viewModel.addViewOnly(owner))
        assertEquals("amber", store.config.value.accountSigningModes[owner])
        assertEquals(listOf(second), store.config.value.accountNpubs)
    }

    @Test
    fun `an added bunker account keeps its bunker`() {
        assertEquals(ALREADY_ADDED, viewModel.addViewOnly(" $second "))
        assertEquals("nip46", store.config.value.accountSigningModes[second])
        assertEquals(listOf(second), store.config.value.accountNpubs)
    }

    @Test
    fun `a new npub is still added as view-only`() {
        assertEquals(null, viewModel.addViewOnly(fresh))
        assertEquals(listOf(second, fresh), store.config.value.accountNpubs)
        assertEquals("local", store.config.value.accountSigningModes[fresh])
    }
}
