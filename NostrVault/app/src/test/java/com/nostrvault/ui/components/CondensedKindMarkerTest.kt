package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Date

class CondensedKindMarkerTest {

    private fun note(
        kind: Int,
        tags: List<List<String>> = emptyList(),
        content: String = "x",
        id: String = "n$kind",
    ) = FeedNote(id = id, pubkey = "a".repeat(64), content = content, createdAt = Date(0), tags = tags, kind = kind)

    private val recipeTags = listOf(listOf("d", "soup"), listOf("t", "ZapCooking"))

    @Test fun articleIsMarked() =
        assertEquals(CondensedKindMarker.ARTICLE, CondensedKindMarker.of(note(30023)))

    @Test fun articleWithACookingTagIsARecipe() {
        assertEquals(CondensedKindMarker.RECIPE, CondensedKindMarker.of(note(30023, recipeTags)))
        assertEquals(CondensedKindMarker.RECIPE, CondensedKindMarker.of(note(30023, listOf(listOf("t", "nostrcooking")))))
    }

    @Test fun highlightIsMarked() =
        assertEquals(CondensedKindMarker.HIGHLIGHT, CondensedKindMarker.of(note(9802)))

    @Test fun pollIsMarked() =
        assertEquals(CondensedKindMarker.POLL, CondensedKindMarker.of(note(1068)))

    @Test fun plainNoteReplyAndCommentAreNot() {
        assertNull(CondensedKindMarker.of(note(1)))
        assertNull(CondensedKindMarker.of(note(1, listOf(listOf("e", "b".repeat(64), "", "reply")))))
        assertNull(CondensedKindMarker.of(note(1111)))
    }

    @Test fun cookingTagOnAPlainNoteIsNotARecipe() =
        assertNull(CondensedKindMarker.of(note(1, recipeTags)))

    @Test fun quoteOfAnArticleIsNotMarked() {
        val quote = note(1, listOf(listOf("q", "c".repeat(64))), content = "nostr:naddr1qq…")
        assertNull(CondensedKindMarker.of(quote))
    }

    @Test fun resolvedBareRepostShowsItsOriginalsKind() {
        val bare = note(6, listOf(listOf("e", "c".repeat(64)), listOf("p", "d".repeat(64))), content = "")
        assertNull("still loading: nothing to mark yet", CondensedKindMarker.of(bare))
        assertEquals(CondensedKindMarker.ARTICLE, CondensedKindMarker.of(bare.withRepostedOriginal(note(30023))))
        assertEquals(CondensedKindMarker.RECIPE, CondensedKindMarker.of(bare.withRepostedOriginal(note(30023, recipeTags))))
        assertEquals(CondensedKindMarker.POLL, CondensedKindMarker.of(bare.withRepostedOriginal(note(1068))))
        assertNull(CondensedKindMarker.of(bare.withRepostedOriginal(note(1))))
    }

    @Test fun embeddedRepostReadsTheInnerEventsKindAndTags() {
        val inner = """{"id":"${"c".repeat(64)}","pubkey":"${"d".repeat(64)}","kind":30023,"created_at":1,""" +
            """"content":"# Soup","tags":[["t","zapcooking"]]}"""
        val repost = note(6, listOf(listOf("e", "c".repeat(64))), content = inner)
        assertEquals(CondensedKindMarker.RECIPE, CondensedKindMarker.of(repost))
    }
}
