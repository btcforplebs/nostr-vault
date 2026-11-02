package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A saved reply draft names the note it answers in the drafts list (iOS: DraftReplyParentTests). */
class DraftReplyParentTest {
    private val parent = "a".repeat(64)
    private val other = "b".repeat(64)

    private fun reply(tags: List<List<String>>) =
        Draft(content = "hi", replyToId = "d".repeat(64), tags = tags)

    @Test
    fun `the parent's author is the first p tag`() {
        val d = reply(listOf(listOf("d", "x"), listOf("e", "c".repeat(64), "", "root"), listOf("p", parent), listOf("p", other)))
        assertEquals(parent, DraftReplyParent.parentPubkey(d))
    }

    @Test
    fun `a new note draft has no parent`() {
        assertNull(DraftReplyParent.parentPubkey(Draft(content = "hi", tags = listOf(listOf("p", parent)))))
    }

    @Test
    fun `the line shows the first non-empty line of their note`() {
        assertEquals("↩ Logen: gm everyone", DraftReplyParent.line("Logen", "\n  gm everyone  \nsecond"))
    }

    @Test
    fun `before the note loads the line names who it replies to`() {
        assertEquals("↩ Reply to Logen", DraftReplyParent.line("Logen", null))
        assertEquals("↩ Reply to Logen", DraftReplyParent.line("Logen", "  \n "))
    }
}
