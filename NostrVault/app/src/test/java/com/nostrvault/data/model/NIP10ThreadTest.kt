package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/NIP10ThreadTests.swift —
 * if a rule changes on one platform it should fail here too.
 */
class NIP10ThreadTest {
    private fun parent(vararg tags: List<String>) = NIP10Thread.parentEventId(1, tags.toList())

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

    // NIP-22 comments

    /** An Amethyst-style comment answering another comment under a kind 1 note. */
    private val nestedComment: List<List<String>> = listOf(
        listOf("E", "root", "wss://r", "rootauthor"), listOf("K", "1"), listOf("P", "rootauthor"),
        listOf("e", "parentcomment", "wss://r", "parentauthor"), listOf("k", "1111"), listOf("p", "parentauthor"),
    )

    @Test fun commentParentIsLowercaseE() {
        // The fourth slot is a pubkey, not a NIP-10 marker; it must not matter.
        assertEquals("parentcomment", NIP10Thread.parentEventId(1111, nestedComment))
    }

    @Test fun commentOnAnAddressHasNoParentEvent() {
        assertNull(NIP10Thread.parentEventId(1111, listOf(
            listOf("A", "30023:pk:d"), listOf("a", "30023:pk:d"), listOf("k", "30023"))))
    }

    @Test fun rootEventId() {
        assertEquals("root", NIP10Thread.rootEventId(1111, nestedComment))
        assertEquals("root", NIP10Thread.rootEventId(1, listOf(
            listOf("e", "quoted", "", "mention"), listOf("e", "root", "", "root"), listOf("e", "parent", "", "reply"))))
        assertEquals("root", NIP10Thread.rootEventId(1, listOf(listOf("e", "root"), listOf("e", "parent"))))
        assertNull(NIP10Thread.rootEventId(1, listOf(listOf("e", "quoted", "", "mention"))))
    }

    @Test fun onlyCommentsOnNotesAreNoteComments() {
        assertTrue(NIP10Thread.isNoteComment(1111, nestedComment))
        assertFalse(NIP10Thread.isNoteComment(1111, listOf(
            listOf("E", "v"), listOf("K", "21"), listOf("e", "v"), listOf("k", "21"))))
        assertFalse(NIP10Thread.isNoteComment(1, listOf(listOf("K", "1"))))
    }

    @Test fun replyKindMatchesTheParent() {
        assertEquals(1111, NIP10Thread.replyKind(1111))
        assertEquals(1, NIP10Thread.replyKind(1))
    }

    @Test fun commentReplyTagsKeepRootAndNameTheParent() {
        val tags = NIP10Thread.commentReplyTags("c2", "author2", nestedComment, "wss://me")
        assertEquals(listOf(
            listOf("E", "root", "wss://r", "rootauthor"), listOf("K", "1"), listOf("P", "rootauthor"),
            listOf("e", "c2", "wss://me", "author2"), listOf("k", "1111"), listOf("p", "author2"),
        ), tags)
        assertEquals("c2", NIP10Thread.parentEventId(1111, tags))
        assertEquals("root", NIP10Thread.rootEventId(1111, tags))
    }
}
