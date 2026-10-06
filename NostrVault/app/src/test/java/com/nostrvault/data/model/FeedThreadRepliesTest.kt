package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rules for replies fetched under Popular and Global's threaded cards. */
class FeedThreadRepliesTest {

    private fun note(
        id: String,
        tags: List<List<String>> = emptyList(),
        author: String = "alice",
        content: String = "hello there",
        kind: Int = 1,
    ) = FeedNote.fromEvent(id, author, content, tags, 1_000, kind)

    private fun reply(id: String, root: String, parent: String = root, author: String = "bob") = note(
        id,
        tags = buildList {
            add(listOf("e", root, "", "root"))
            if (parent != root) add(listOf("e", parent, "", "reply"))
        },
        author = author,
    )

    @Test
    fun `only Popular and Global fetch replies`() {
        assertTrue(FeedThreadReplies.fetchesReplies(FeedMode.POPULAR))
        assertTrue(FeedThreadReplies.fetchesReplies(FeedMode.GLOBAL))
        assertFalse(FeedThreadReplies.fetchesReplies(FeedMode.FOLLOWING))
        assertFalse(FeedThreadReplies.fetchesReplies(FeedMode.DISCOVERY))
    }

    @Test
    fun `filter asks for kind 1 replies tagging the posts`() {
        assertEquals(
            """{"kinds":[1],"#e":["a","b"],"limit":500}""",
            FeedThreadReplies.filter(listOf("a", "b")),
        )
    }

    @Test
    fun `a reply deeper in the thread counts by its root`() {
        val deep = reply("r2", root = "post", parent = "r1")
        assertTrue(FeedThreadReplies.isInThread(deep.kind, deep.tags, setOf("post")))
    }

    @Test
    fun `a note that only tags a post as its parent elsewhere is not in its thread`() {
        // Its root is another conversation; "post" is just the note it answers
        // inside that one, so it would open a stray thread.
        val stray = reply("r", root = "elsewhere", parent = "post")
        assertFalse(FeedThreadReplies.isInThread(stray.kind, stray.tags, setOf("post")))
    }

    @Test
    fun `a quote is not a reply`() {
        val quote = note("q", tags = listOf(listOf("e", "post", "", "mention")))
        assertFalse(FeedThreadReplies.isInThread(quote.kind, quote.tags, setOf("post")))
    }

    @Test
    fun `a positional reply counts`() {
        val legacy = note("r", tags = listOf(listOf("e", "post")))
        assertTrue(FeedThreadReplies.isInThread(legacy.kind, legacy.tags, setOf("post")))
    }

    @Test
    fun `admits drops blocked people, spam and replies outside the trust set`() {
        val roots = setOf("post")
        val ok = reply("r", root = "post")
        assertTrue(FeedThreadReplies.admits(ok, roots, blocked = emptySet(), trusted = null))
        assertFalse(FeedThreadReplies.admits(ok, roots, blocked = setOf("bob"), trusted = null))
        assertTrue(FeedThreadReplies.admits(ok, roots, blocked = emptySet(), trusted = setOf("bob")))
        assertFalse(FeedThreadReplies.admits(ok, roots, blocked = emptySet(), trusted = setOf("carol")))
        // No graph yet: Global fails closed.
        assertFalse(FeedThreadReplies.admits(ok, roots, blocked = emptySet(), trusted = emptySet()))

        val spam = note("s", tags = ok.tags, author = "bob", content = "free bitcoin here")
        assertFalse(FeedThreadReplies.admits(spam, roots, blocked = emptySet(), trusted = null))
        val elsewhere = reply("x", root = "other")
        assertFalse(FeedThreadReplies.admits(elsewhere, roots, blocked = emptySet(), trusted = null))
    }

    @Test
    fun `attach appends replies into the posts and nothing else`() {
        val posts = listOf(note("a"), note("b"), reply("streamed", root = "a"))
        val fetched = listOf(
            reply("ra", root = "a"),
            // Delivered by the stream already.
            reply("streamed", root = "a"),
            // Its post has left the list (blocked since, or a trust switch).
            reply("gone", root = "c"),
            // Blocked after the fetch.
            reply("rb", root = "b", author = "mallory"),
        )

        val pool = FeedThreadReplies.attach(posts, fetched, blocked = setOf("mallory"))
        assertEquals(listOf("a", "b", "streamed", "ra"), pool.map { it.id })
    }

    @Test
    fun `attach with nothing fetched is the feed itself`() {
        val posts = listOf(note("a"))
        assertTrue(FeedThreadReplies.attach(posts, emptyList(), emptySet()) === posts)
    }
}
