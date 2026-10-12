package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

class NoteDeletionTest {
    private fun event(id: String) =
        NostrEvent(id = id, pubkey = "a".repeat(64), createdAt = 0, kind = 1, tags = emptyList(), content = id, sig = "")

    @Test
    fun `the request names the post`() {
        assertEquals(listOf(listOf("e", "abc")), NoteDeletion.requestTags("abc"))
    }

    @Test
    fun `the deleted post leaves the local list and nothing else does`() {
        val events = listOf(event("keep1"), event("gone"), event("keep2"))
        assertEquals(listOf("keep1", "keep2"), NoteDeletion.without(events, "gone").map { it.id })
    }

    @Test
    fun `an id that is not loaded changes nothing`() {
        val events = listOf(event("keep1"), event("keep2"))
        assertEquals(events, NoteDeletion.without(events, "missing"))
    }
}
