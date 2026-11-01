package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ThreadParentLookupTest {

    private fun note(id: String, parent: String?) = FeedNote.fromEvent(
        id = id, pubkey = "b".repeat(64), content = id,
        tags = parent?.let { listOf(listOf("e", it, "", "reply")) } ?: emptyList(),
        createdAt = 1_700_000_000L, kind = 1,
    )

    @Test
    fun replyWithNoChainLacksItsParent() {
        val reply = note("c".repeat(64), "p".repeat(64))
        assertEquals("p".repeat(64), ThreadParentLookup.missingParentId(reply, emptyList()))
    }

    @Test
    fun chainStoppingShortLacksTheTopNotesParent() {
        val reply = note("c".repeat(64), "p".repeat(64))
        val parent = note("p".repeat(64), "g".repeat(64))
        assertEquals("g".repeat(64), ThreadParentLookup.missingParentId(reply, listOf(parent)))
    }

    @Test
    fun chainReachingARootLacksNothing() {
        val reply = note("c".repeat(64), "p".repeat(64))
        val root = note("p".repeat(64), null)
        assertNull(ThreadParentLookup.missingParentId(reply, listOf(root)))
        assertNull(ThreadParentLookup.missingParentId(root, emptyList()))
    }
}
