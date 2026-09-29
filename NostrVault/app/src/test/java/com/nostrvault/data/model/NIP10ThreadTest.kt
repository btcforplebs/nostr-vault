package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/NIP10ThreadTests.swift —
 * if a rule changes on one platform it should fail here too.
 */
class NIP10ThreadTest {
    private fun parent(vararg tags: List<String>) = NIP10Thread.parentEventId(tags.toList())

    @Test fun quoteIsNotAReply() {
        // A Primal quote: its only e tag is the quoted note, marked "mention".
        assertNull(parent(listOf("e", "quoted", "", "mention"), listOf("client", "Primal iOS")))
    }

    @Test fun replyMarkerWins() {
        assertEquals("parent", parent(listOf("e", "root", "", "root"), listOf("e", "parent", "", "reply")))
    }

    @Test fun replyThatAlsoQuotesPointsAtItsParent() {
        assertEquals("parent", parent(
            listOf("e", "root", "", "root"), listOf("e", "parent", "", "reply"), listOf("e", "quoted", "", "mention")))
    }

    @Test fun directReplyToRootWithOnlyARootMarker() {
        assertEquals("root", parent(listOf("e", "root", "wss://r", "root"), listOf("e", "quoted", "", "mention")))
    }

    @Test fun positionalLastUnmarkedTag() {
        assertEquals("parent", parent(listOf("e", "root"), listOf("e", "parent")))
        assertEquals("parent", parent(listOf("e", "root"), listOf("e", "parent"), listOf("e", "quoted", "", "mention")))
    }

    @Test fun noETags() {
        assertNull(parent(listOf("p", "someone"), listOf("t", "nostr")))
    }
}
