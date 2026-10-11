package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A block on DMs: the opened message's real sender is checked, conversations
 * with a blocked person are hidden (not deleted), and they never alert.
 */
class BlockedPeopleTest {
    private val blockedHex = "b".repeat(64)
    private val friendHex = "f".repeat(64)

    private data class Convo(val id: String)

    @Test
    fun conversationWithBlockedPersonIsHidden() {
        val all = listOf(Convo(friendHex), Convo(blockedHex))
        assertEquals(listOf(friendHex), BlockedPeople.visibleConversations(all, setOf(blockedHex)) { it.id }.map { it.id })
    }

    /** Unblocking is just an empty block list: nothing was removed, so it shows again. */
    @Test
    fun unblockShowsTheConversationAgain() {
        val all = listOf(Convo(friendHex), Convo(blockedHex))
        assertEquals(all, BlockedPeople.visibleConversations(all, emptySet()) { it.id })
    }

    @Test
    fun blockedSenderNeverAlerts() {
        assertFalse(BlockedPeople.mayAlert(blockedHex, isFromMe = false, blocked = setOf(blockedHex)))
    }

    /** Positive control: the same message from someone not blocked does. */
    @Test
    fun unblockedSenderAlerts() {
        assertTrue(BlockedPeople.mayAlert(friendHex, isFromMe = false, blocked = setOf(blockedHex)))
    }

    @Test
    fun ownCopyNeverAlerts() {
        assertFalse(BlockedPeople.mayAlert(friendHex, isFromMe = true, blocked = emptySet()))
    }

    /** Block lists hold lowercase hex; a sender in upper case is still caught. */
    @Test
    fun senderCaseDoesNotEscapeTheBlock() {
        assertTrue(BlockedPeople.isBlocked(blockedHex.uppercase(), setOf(blockedHex)))
        assertFalse(BlockedPeople.isBlocked("", setOf(blockedHex)))
    }
}
