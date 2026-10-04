package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedThreadGrouping
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A blocked person stays out of every row that would show them (iOS #211). */
class BlockedInFeedsTest {

    private val friend = "f".repeat(64)
    private val troll = "b".repeat(64)
    private val blocked = setOf(troll)

    private fun note(id: String, pubkey: String, kind: Int = 1, tags: List<List<String>> = emptyList(),
                     repostedBy: String? = null, content: String = "Morning walk by the river, the light was lovely.") =
        FeedNote.fromEvent(id, pubkey, content, tags, 1_700_000_000L, kind, repostedBy)

    private val trollPost = note("t".repeat(64), troll)
    private val known = mapOf(trollPost.id to trollPost)
    private val authorOf: (String) -> String? = { known[it]?.pubkey }

    @Test fun `own post by a blocked author`() {
        assertTrue(FeedFilterEngine.involvesBlocked(trollPost, blocked, authorOf))
    }

    @Test fun `bare repost of a blocked author, original loaded`() {
        val repost = note("r".repeat(64), friend, kind = 6, tags = listOf(listOf("e", trollPost.id)), content = "")
        assertEquals(trollPost.id, repost.repostedEventId)
        assertTrue(FeedFilterEngine.involvesBlocked(repost, blocked, authorOf))
    }

    @Test fun `bare repost of a blocked author, original not loaded, p tag names them`() {
        val repost = note("r".repeat(64), friend, kind = 6,
            tags = listOf(listOf("e", "9".repeat(64)), listOf("p", troll)), content = "")
        assertTrue(FeedFilterEngine.involvesBlocked(repost, blocked))
    }

    @Test fun `embedded repost by a blocked reposter`() {
        val shared = note("s".repeat(64), friend, repostedBy = troll)
        assertTrue(FeedFilterEngine.involvesBlocked(shared, blocked))
    }

    @Test fun `reply to a blocked author's post`() {
        val reply = note("a".repeat(64), friend, tags = listOf(listOf("e", trollPost.id, "", "reply")))
        assertEquals(trollPost.id, reply.parentEventId)
        assertTrue(FeedFilterEngine.involvesBlocked(reply, blocked, authorOf))
    }

    @Test fun `unrelated notes stay`() {
        val plain = note("c".repeat(64), friend)
        val reply = note("d".repeat(64), friend, tags = listOf(listOf("e", plain.id, "", "reply")))
        assertFalse(FeedFilterEngine.involvesBlocked(plain, blocked, authorOf))
        assertFalse(FeedFilterEngine.involvesBlocked(reply, blocked) { plain.pubkey })
        assertFalse(FeedFilterEngine.involvesBlocked(trollPost, emptySet(), authorOf))
    }

    @Test fun `feed filter drops the reply to a blocked author`() {
        val reply = note("a".repeat(64), friend, tags = listOf(listOf("e", trollPost.id, "", "reply")))
        val plain = note("c".repeat(64), friend)
        val shown = FeedFilterEngine.filterFeedNotes(
            notes = listOf(reply, plain),
            mode = FeedMode.FOLLOWING,
            blocked = blocked,
            showReposts = true,
            showReplies = true,
            followedPubkeys = setOf(friend),
            wotPubkeys = emptySet(),
            authorOf = authorOf,
        )
        assertEquals(listOf(plain.id), shown.map { it.id })
    }

    @Test fun `threaded view drops a conversation a blocked author started`() {
        val reply = note("a".repeat(64), friend, tags = listOf(listOf("e", trollPost.id, "root")))
        val other = note("c".repeat(64), friend)
        val threads = FeedThreadGrouping.build(listOf(reply, other)) { id ->
            known[id]?.takeIf { it.pubkey !in blocked }
        }
        assertTrue(threads.any { it.rootId == trollPost.id && it.root == null })
        val kept = FeedThreadGrouping.withoutBlocked(threads, blocked) { known[it] }
        assertEquals(listOf(other.id), kept.map { it.rootId })
    }
}
