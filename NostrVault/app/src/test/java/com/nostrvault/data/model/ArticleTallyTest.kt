package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/ArticleTallyTests.swift. */
class ArticleTallyTest {
    private val id = "a".repeat(64)
    private val author = "b".repeat(64)
    private val coord = "30023:$author:my-post"
    private var n = 0

    private fun event(
        kind: Int,
        tags: List<List<String>>,
        content: String = "hi",
        pubkey: String? = null,
        at: Long = 1_700_000_000,
    ): ArticleEngagementEvent {
        n += 1
        return ArticleEngagementEvent("ev$n", kind, pubkey ?: "p$n", content, at + n, tags)
    }

    private fun tally(events: List<ArticleEngagementEvent>) =
        ArticleTallies.tally(events, id, coord, nowSeconds = 1_800_000_000)

    @Test fun likesCountPeopleNotReactionsAndSkipDislikes() {
        val t = tally(listOf(
            event(7, listOf(listOf("a", coord)), content = "+", pubkey = "alice"),
            event(7, listOf(listOf("e", id)), content = "🔥", pubkey = "alice"),
            event(7, listOf(listOf("e", id)), content = "+", pubkey = "bob"),
            event(7, listOf(listOf("e", id)), content = "-", pubkey = "carol"),
            event(7, listOf(listOf("e", "other")), content = "+", pubkey = "dave"),
        ))
        assertEquals(setOf("alice", "bob"), t.likers)
    }

    @Test fun zapsSumTheRequestedAmount() {
        val request = """{"kind":9734,"tags":[["amount","21000"]]}"""
        val t = tally(listOf(
            event(9735, listOf(listOf("e", id), listOf("description", request))),
            event(9735, listOf(listOf("a", coord), listOf("amount", "1000000"))),
            event(9735, listOf(listOf("e", "other"), listOf("description", request))),
        ))
        assertEquals(2, t.zaps)
        assertEquals(21L + 1000L, t.zapSats)
    }

    @Test fun commentsSplitTopLevelFromReplies() {
        val top = event(1111, listOf(listOf("A", coord), listOf("K", "30023"), listOf("a", coord), listOf("k", "30023")))
        val reply = event(1111, listOf(listOf("A", coord), listOf("K", "30023"), listOf("e", top.id), listOf("k", "1111")))
        val legacy = event(1, listOf(listOf("e", id, "", "root"), listOf("a", coord)))
        val legacyReply = event(1, listOf(listOf("e", id, "", "root"), listOf("e", legacy.id, "", "reply")))
        val mention = event(1, listOf(listOf("e", id, "", "mention")))
        val t = tally(listOf(top, reply, legacy, legacyReply, mention))
        assertEquals(4, t.commentCount)
        assertEquals(listOf(top.id, legacy.id), t.topLevelComments.map { it.id })
        assertEquals(1, t.replyCounts[top.id])
        assertEquals(1, t.replyCounts[legacy.id])
    }

    @Test fun duplicatesAndFutureDatedEventsAreDropped() {
        val like = event(7, listOf(listOf("e", id)), pubkey = "alice")
        val future = event(1111, listOf(listOf("a", coord)), at = 2_000_000_000)
        val t = tally(listOf(like, like, future))
        assertEquals(1, t.likers.size)
        assertEquals(0, t.commentCount)
    }

    @Test fun filtersAskByIdAndCoordinateAndCommentRoot() {
        val filters = ArticleTallies.engagementFilters(id, coord)
        assertTrue(filters.any { it.contains("\"#E\":[\"$id\"]") })
        assertTrue(filters.any { it.contains("\"#A\":[\"$coord\"]") })
        assertEquals(2, ArticleTallies.engagementFilters(id, null).size)
    }
}
