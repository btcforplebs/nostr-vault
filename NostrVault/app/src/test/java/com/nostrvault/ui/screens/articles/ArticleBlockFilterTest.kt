package com.nostrvault.ui.screens

import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.ArticleTallies
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Blocked people's highlights and comments under an article are hidden and
 * not counted. Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/ArticleBlockFilterTests.swift.
 */
class ArticleBlockFilterTest {
    private val articleId = "a".repeat(64)
    private val blockedKey = "bb"
    private val friend = "ff"

    private fun event(id: String, kind: Int, pubkey: String, content: String = "x",
                      tags: List<List<String>> = listOf(listOf("e", articleId))) =
        ArticleEngagementEvent(id, kind, pubkey, content, 1_700_000_000, tags)

    private fun highlight(id: String, pubkey: String) =
        ArticleHighlight(id, pubkey, "a passage", null, 1_700_000_000, listOf(listOf("e", articleId)))

    @Test fun blockedCommentIsNotShownOrCounted() {
        val events = listOf(
            event("c1", ArticleTallies.COMMENT_KIND, blockedKey, tags = listOf(listOf("E", articleId), listOf("e", articleId))),
            event("c2", ArticleTallies.COMMENT_KIND, friend, tags = listOf(listOf("E", articleId), listOf("e", articleId))),
            event("r1", ArticleTallies.COMMENT_KIND, blockedKey, tags = listOf(listOf("E", articleId), listOf("e", "c2"))),
        )
        val tally = ArticleTallies.tally(ArticleBlockFilter.visibleEvents(events, setOf(blockedKey)), articleId, null)
        assertEquals(listOf(friend), tally.topLevelComments.map { it.pubkey })
        assertEquals(1, tally.commentCount)
        assertNull(tally.replyCounts["c2"])
    }

    @Test fun blockedLikeIsNotCounted() {
        val events = listOf(
            event("l1", ArticleTallies.REACTION_KIND, blockedKey, content = "+"),
            event("l2", ArticleTallies.REACTION_KIND, friend, content = "+"),
        )
        val tally = ArticleTallies.tally(ArticleBlockFilter.visibleEvents(events, setOf(blockedKey)), articleId, null)
        assertEquals(setOf(friend), tally.likers)
    }

    @Test fun blockedHighlightIsNotShown() {
        val shown = ArticleBlockFilter.visibleHighlights(listOf(highlight("h1", blockedKey), highlight("h2", friend)), setOf(blockedKey))
        assertEquals(listOf(friend), shown.map { it.pubkey })
    }

    /** Blocks are stored lowercase; a relay may send an uppercase pubkey. */
    @Test fun uppercasePubkeyStillBlocked() {
        val events = listOf(event("l1", ArticleTallies.REACTION_KIND, "BB", content = "+"))
        assertTrue(ArticleBlockFilter.visibleEvents(events, setOf(blockedKey)).isEmpty())
        assertTrue(ArticleBlockFilter.visibleHighlights(listOf(highlight("h1", "BB")), setOf(blockedKey)).isEmpty())
    }

    /** A zap receipt is signed by the Lightning provider, not the sender. */
    @Test fun zapReceiptsStay() {
        val events = listOf(event("z1", ArticleTallies.ZAP_RECEIPT_KIND, blockedKey))
        assertEquals(1, ArticleBlockFilter.visibleEvents(events, setOf(blockedKey)).size)
    }

    @Test fun nothingBlockedKeepsEverything() {
        val events = listOf(event("c1", ArticleTallies.COMMENT_KIND, blockedKey))
        assertEquals(1, ArticleBlockFilter.visibleEvents(events, emptySet()).size)
        assertEquals(1, ArticleBlockFilter.visibleHighlights(listOf(highlight("h1", blockedKey)), emptySet()).size)
    }

    /** Unblocking brings them back: the filter never drops what it was given. */
    @Test fun unblockRestores() {
        val events = listOf(event("c1", ArticleTallies.COMMENT_KIND, blockedKey, tags = listOf(listOf("E", articleId), listOf("e", articleId))))
        assertEquals(0, ArticleTallies.tally(ArticleBlockFilter.visibleEvents(events, setOf(blockedKey)), articleId, null).commentCount)
        assertEquals(1, ArticleTallies.tally(ArticleBlockFilter.visibleEvents(events, emptySet()), articleId, null).commentCount)
    }
}
