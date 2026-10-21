package com.nostrvault.ui.screens.dm

import androidx.lifecycle.SavedStateHandle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The right pane's conversation belongs to the account that picked it. */
class DMPaneSelectionTest {

    private var account = "alice"
    private val state = SavedStateHandle()
    private val selection = DMPaneSelection(state) { account }

    @Test
    fun nothingIsOpenUntilPicked() {
        assertNull(selection.current())
    }

    @Test
    fun aPickOpensForTheAccountThatMadeIt() {
        selection.select("bob")
        assertEquals("bob", selection.current())
        assertEquals("bob", selection.changes.value)
    }

    @Test
    fun anotherAccountNeverSeesThePick() {
        selection.select("bob")
        account = "carol"
        assertNull(selection.current())
    }

    @Test
    fun clearingOnASwitchKeepsItFromReopeningOnTheWayBack() {
        selection.select("bob")
        account = "carol"
        selection.clear()
        account = "alice"
        assertNull(selection.current())
        assertNull(selection.changes.value)
    }

    @Test
    fun aPickAfterClearingStillReachesTheFlow() {
        selection.select("bob")
        selection.clear()
        selection.select("dave")
        assertEquals("dave", selection.changes.value)
        assertEquals("dave", selection.current())
    }

    @Test
    fun thePickSurvivesSavedState() {
        selection.select("bob")
        val saved = state.keys().associateWith { state.get<Any>(it) }
        val restored = DMPaneSelection(SavedStateHandle(saved)) { account }
        assertEquals("bob", restored.current())
    }
}
