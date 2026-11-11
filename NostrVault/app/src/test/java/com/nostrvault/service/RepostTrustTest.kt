package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A kind 6 can embed any JSON with any `pubkey`. Only a verified embedded
 * event lends the row its author, and Global trusts the repost's signer
 * (iOS RepostTrustTests).
 */
class RepostTrustTest {
    private val stranger = "a".repeat(64)
    private val trusted = "b".repeat(64)
    private val otherTrusted = "d".repeat(64)
    private val originalId = "c".repeat(64)

    private fun embedded(author: String) =
        """{"id":"$originalId","kind":1,"pubkey":"$author","created_at":1700000000,"tags":[],"content":"send sats to X","sig":"00"}"""

    private fun repost(signer: String, author: String, verify: (String) -> Boolean) = FeedNote.fromEvent(
        "r".repeat(64), signer, embedded(author), listOf(listOf("e", originalId), listOf("p", author)),
        1_700_000_100L, 6, signer, verify,
    )

    // showReposts must be true: false drops every kind 6 and would pass this without the fix.
    private fun global(notes: List<FeedNote>, web: Set<String>) = FeedFilterEngine.filterFeedNotes(
        notes, FeedMode.GLOBAL, emptySet(), showReposts = true, showReplies = true,
        followedPubkeys = emptySet(), wotPubkeys = web,
    )

    @Test fun `a trusted member cannot forge another member's note`() {
        val forged = repost(trusted, otherTrusted) { false }
        assertEquals(trusted, forged.pubkey)
        assertEquals("", forged.content)
        assertEquals(originalId, forged.repostedEventId)
        assertNull(forged.originalCreatedAtSecs)
    }

    @Test fun `a stranger's repost is not admitted by the author it names`() {
        assertEquals(0, global(listOf(repost(stranger, trusted) { true }), setOf(trusted)).size)
        assertEquals(0, global(listOf(repost(stranger, trusted) { false }), setOf(trusted)).size)
    }

    @Test fun `a verified embed still unpacks and the raw content is what is checked`() {
        var seen: String? = null
        val note = repost(trusted, stranger) { seen = it; true }
        assertEquals(embedded(stranger), seen)
        assertEquals(stranger, note.pubkey)
        assertEquals("send sats to X", note.content)
        assertEquals(trusted, note.repostedBy)
        assertEquals(1, global(listOf(note), setOf(trusted)).size)
    }
}
