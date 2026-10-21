package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A block made on a thread page applies to everything on it at once: the note
 * shown full size, the notes above it, and the quotes and highlights under it.
 * iOS: BlockedPeopleThreadTests.
 */
class BlockedPeopleThreadTest {
    private val blockedHex = "b".repeat(64)
    private val friendHex = "f".repeat(64)
    private val blocked = setOf(blockedHex)

    private data class Note(val id: String, val pubkey: String)

    @Test
    fun openedNoteByBlockedPersonBecomesAPlaceholder() {
        assertEquals(
            BlockedPeople.FocusedNote.PLACEHOLDER,
            BlockedPeople.focusedNote(blockedHex, isOpenedNote = true, blocked = blocked),
        )
    }

    @Test
    fun tappedIntoReplyByBlockedPersonGoesBackToTheOpenedNote() {
        assertEquals(
            BlockedPeople.FocusedNote.BACK_TO_OPENED,
            BlockedPeople.focusedNote(blockedHex, isOpenedNote = false, blocked = blocked),
        )
    }

    /** Positive control: someone you did not block stays on screen. */
    @Test
    fun noteByUnblockedPersonIsShown() {
        assertEquals(
            BlockedPeople.FocusedNote.SHOWN,
            BlockedPeople.focusedNote(friendHex, isOpenedNote = true, blocked = blocked),
        )
    }

    @Test
    fun upperCaseAuthorIsStillCaught() {
        assertEquals(
            BlockedPeople.FocusedNote.PLACEHOLDER,
            BlockedPeople.focusedNote(blockedHex.uppercase(), isOpenedNote = true, blocked = blocked),
        )
    }

    @Test
    fun quotesByBlockedPersonAreLeftOut() {
        val quotes = listOf(Note("q1", friendHex), Note("q2", blockedHex), Note("q3", friendHex))
        assertEquals(listOf("q1", "q3"), BlockedPeople.visibleNotes(quotes, blocked) { it.pubkey }.map { it.id })
    }

    /** Unblocking is an empty block list: every quote shows again. */
    @Test
    fun emptyBlockListKeepsEveryNote() {
        val quotes = listOf(Note("q1", friendHex), Note("q2", blockedHex))
        assertEquals(quotes, BlockedPeople.visibleNotes(quotes, emptySet()) { it.pubkey })
    }
}
