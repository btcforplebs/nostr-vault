package com.nostrvault.ui.screens.dashboard

import com.nostrvault.data.model.VaultContentFilter
import com.nostrvault.ui.screens.dashboard.NotesFilterPick.State
import com.nostrvault.ui.screens.dashboard.NotesFilterPick.Tap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** Notes, Articles and Highlights filters after the toolbar audit (Logen 2026-11-04). */
class NotesFilterPickTest {
    private val all = State(VaultContentFilter.ALL, false)

    @Test fun `nothing lit is All`() = assertNull(all.lit)

    @Test fun `tapping the lit filter again goes back to All`() {
        val mine = NotesFilterPick.after(all, Tap.MINE)
        assertEquals(State(VaultContentFilter.MINE, false), mine)
        assertEquals(all, NotesFilterPick.after(mine, Tap.MINE))
        val recipes = NotesFilterPick.after(all, Tap.RECIPES)
        assertEquals(State(VaultContentFilter.ALL, true), recipes)
        assertEquals(all, NotesFilterPick.after(recipes, Tap.RECIPES))
    }

    @Test fun `Recipes is a radio beside Mine, not a toggle that stacks`() {
        val mine = State(VaultContentFilter.MINE, false)
        assertEquals(State(VaultContentFilter.ALL, true), NotesFilterPick.after(mine, Tap.RECIPES))
        assertEquals(State(VaultContentFilter.MINE, false), NotesFilterPick.after(State(VaultContentFilter.ALL, true), Tap.MINE))
    }

    @Test fun `a list left on Mentions or Outside lights nothing, and Mine still picks Mine`() {
        for (f in listOf(VaultContentFilter.TAGGED, VaultContentFilter.OUTSIDE)) {
            assertNull(State(f, false).lit)
            assertEquals(State(VaultContentFilter.MINE, false), NotesFilterPick.after(State(f, false), Tap.MINE))
        }
    }

    @Test fun `the toolbars carry no All, Notes @ or Outside button`() {
        val dash = File("src/main/java/com/nostrvault/ui/screens/dashboard/DashboardScreen.kt").readText()
            .substringAfter("private fun RowScope.RelayFilters(").substringBefore("VaultViewMode.LIKES ->")
        assertFalse(dash.contains("NostrVaultIcons.At"))
        assertFalse(dash.contains("NostrVaultIcons.OutsideNetwork"))
        assertFalse(dash.contains("\"All\""))
        val vault = File("src/main/java/com/nostrvault/ui/screens/VaultActivityScreen.kt").readText()
            .substringAfter("VaultRightPill {").substringBefore("if (chips.isNotEmpty())")
        assertFalse(vault.contains("NostrVaultIcons.Layers"))
        assertFalse(vault.contains("contentDescription = \"All\""))
    }
}
