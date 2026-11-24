package com.nostrvault.ui.components

/**
 * Whether the full-screen viewer offers Delete for a file.
 *
 * Delete signs a Blossom delete with the active account's key, so it is only
 * offered for that account's own media: the note the file came from was
 * posted by the active account. A file with no known poster gets no Delete.
 * iOS: MediaDeleteGate.swift.
 */
internal object MediaDeleteGate {
    fun showsDelete(poster: String?, activePubkey: String): Boolean {
        val me = activePubkey.trim().lowercase()
        val who = poster?.trim()?.lowercase().orEmpty()
        return me.isNotEmpty() && who.isNotEmpty() && who == me
    }
}
