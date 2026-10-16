package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A quote card hides a blocked person's note, and a quoted stream whose
 * streamer is blocked even when a service key signed it. iOS BlockedPeopleTests.
 */
class BlockedPeopleQuoteTest {
    private val blockedHex = "b".repeat(64)
    private val friendHex = "f".repeat(64)
    private val serviceHex = "5".repeat(64)

    private fun streamTags(host: String) = listOf(
        listOf("d", "stream-1"),
        listOf("p", host, "", "Host"),
    )

    @Test
    fun quoteByBlockedPersonIsHidden() {
        assertFalse(BlockedPeople.showsQuote(blockedHex, 1, emptyList(), setOf(blockedHex)))
    }

    @Test
    fun quoteByAnyoneElseShows() {
        assertTrue(BlockedPeople.showsQuote(friendHex, 1, emptyList(), setOf(blockedHex)))
        assertTrue(BlockedPeople.showsQuote(blockedHex, 1, emptyList(), emptySet()))
    }

    /** The blocked list holds lowercase hex; an uppercase author still matches. */
    @Test
    fun authorCaseDoesNotMatter() {
        assertFalse(BlockedPeople.showsQuote(blockedHex.uppercase(), 1, emptyList(), setOf(blockedHex)))
    }

    @Test
    fun streamSignedByServiceKeyIsHiddenWhenItsHostIsBlocked() {
        assertFalse(BlockedPeople.showsQuote(serviceHex, 30311, streamTags(blockedHex), setOf(blockedHex)))
        assertTrue(BlockedPeople.showsQuote(serviceHex, 30311, streamTags(friendHex), setOf(blockedHex)))
    }

    /** A Host tag only counts on a stream: a kind-1 note tagging a blocked host still shows. */
    @Test
    fun hostTagOnAPlainNoteIsNotChecked() {
        assertTrue(BlockedPeople.showsQuote(friendHex, 1, streamTags(blockedHex), setOf(blockedHex)))
    }
}
