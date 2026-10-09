package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The threads spec Logen shared on 2026-10-03, with Tom's default for notes.
 *  Same cases as the Swift ThreadSpecTests. */
class ThreadSpecTest {
    private val id = "a".repeat(64)
    private val pk = "b".repeat(64)

    @Test fun replyKindTable() {
        assertEquals(1, NIP10Thread.replyKind(1))
        assertEquals(1111, NIP10Thread.replyKind(1, asComment = true))
        assertEquals(1111, NIP10Thread.replyKind(1111))
        assertEquals(1111, NIP10Thread.replyKind(30023))
        assertEquals(1111, NIP10Thread.replyKind(34236))
        assertEquals(1111, NIP10Thread.replyKind(20))
    }

    @Test fun originalNoteOnlyForUnthreadedKind1() {
        assertTrue(NIP10Thread.isOriginalNote(1, listOf(listOf("p", pk))))
        assertTrue(NIP10Thread.isOriginalNote(1, listOf(listOf("e", id, "", "mention"))))
        assertFalse(NIP10Thread.isOriginalNote(1, listOf(listOf("e", id, "", "root"))))
        assertFalse(NIP10Thread.isOriginalNote(30023, emptyList()))
    }

    @Test fun commentOnRegularEvent() {
        assertEquals(
            listOf(
                listOf("E", id, "wss://r", pk), listOf("K", "1"), listOf("P", pk),
                listOf("e", id, "wss://r", pk), listOf("k", "1"), listOf("p", pk),
            ),
            NIP10Thread.commentTags(id, 1, pk, emptyList(), "wss://r"),
        )
    }

    @Test fun commentOnArticleIsRootedByAOnly() {
        val coord = "30023:$pk:my-post"
        val tags = NIP10Thread.commentTags(id, 30023, pk, listOf(listOf("d", "my-post")), "")
        assertEquals(
            listOf(
                listOf("A", coord, ""), listOf("K", "30023"), listOf("P", pk),
                listOf("a", coord, ""), listOf("e", id, "", pk), listOf("k", "30023"), listOf("p", pk),
            ),
            tags,
        )
        assertFalse(tags.any { it[0] == "E" })
    }

    @Test fun replaceableKeepsTrailingColon() {
        assertEquals("0:$pk:", NIP10Thread.coordinate(0, pk, emptyList()))
        assertEquals("10002:$pk:", NIP10Thread.coordinate(10002, pk, emptyList()))
        assertNull(NIP10Thread.coordinate(1, pk, emptyList()))
        assertNull(NIP10Thread.coordinate(30023, pk, emptyList()))
    }

    @Test fun nestedCommentCopiesRootAndPointsAtParent() {
        val root = NIP10Thread.commentTags(id, 30023, pk, listOf(listOf("d", "x")), "")
        val cid = "c".repeat(64); val commenter = "d".repeat(64)
        val nested = NIP10Thread.commentTags(cid, 1111, commenter, root, "")
        assertTrue(nested.contains(listOf("A", "30023:$pk:x", "")))
        assertTrue(nested.contains(listOf("K", "30023")))
        assertTrue(nested.contains(listOf("e", cid, "", commenter)))
        assertTrue(nested.contains(listOf("k", "1111")))
        assertFalse(nested.any { it[0] == "a" })
        assertEquals(cid, NIP10Thread.parentEventId(1111, nested))
    }
}
