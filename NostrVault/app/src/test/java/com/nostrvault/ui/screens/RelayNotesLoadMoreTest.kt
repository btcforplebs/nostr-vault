package com.nostrvault.ui.screens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Relay tab Notes load-more: raise the cap before asking the relay (iOS #273). */
class RelayNotesLoadMoreTest {
    @Test
    fun loadedNotesPastTheCapAreHidden() {
        assertTrue(relayNotesHiddenBelowCap(filteredCount = 180, cap = 50))
        assertTrue(relayNotesHiddenBelowCap(filteredCount = 51, cap = 50))
    }

    @Test
    fun everythingListedMeansAskTheRelay() {
        assertFalse(relayNotesHiddenBelowCap(filteredCount = 50, cap = 50))
        assertFalse(relayNotesHiddenBelowCap(filteredCount = 12, cap = 50))
        assertFalse(relayNotesHiddenBelowCap(filteredCount = 0, cap = 50))
    }
}
