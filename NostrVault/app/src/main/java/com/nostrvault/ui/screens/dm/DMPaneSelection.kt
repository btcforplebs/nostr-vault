package com.nostrvault.ui.screens.dm

import androidx.lifecycle.SavedStateHandle
import kotlinx.coroutines.flow.StateFlow

/**
 * The conversation open in the wide-screen right pane, kept with the account
 * that picked it. Another account never gets it: an opened thread marks
 * itself read, so showing it after a switch would clear an unread the new
 * account hasn't seen. Saved state, so it outlives the process like the
 * `rememberSaveable` it replaces.
 */
internal class DMPaneSelection(
    private val state: SavedStateHandle,
    private val activeAccount: () -> String,
) {
    /** Emits on every pick and clear, for recomposition; read [current] for the value. */
    val changes: StateFlow<String?> = state.getStateFlow(PUBKEY, null)

    fun select(pubkey: String) {
        state[OWNER] = activeAccount()
        state[PUBKEY] = pubkey
    }

    /** Set to null rather than removed: removing a key detaches [changes]. */
    fun clear() {
        state[OWNER] = null
        state[PUBKEY] = null
    }

    /** The picked pubkey, or null when nothing is picked or another account picked it. */
    fun current(): String? =
        state.get<String>(PUBKEY)?.takeIf { state.get<String>(OWNER) == activeAccount() }

    private companion object {
        const val OWNER = "dm_pane_owner"
        const val PUBKEY = "dm_pane_pubkey"
    }
}
