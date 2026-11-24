package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenBridge
import com.nostrvault.util.PublicKeyRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A key whose nsec is public is no longer the person you trusted: Discover
 * leaves it out even when it is in your web, as iOS judges every Discover
 * note through the gate (Tron, #2437 low 2).
 */
class DiscoverPublicKeyTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val friendOfFriend = pk('c')
    private val leaked = pk('e')

    @After fun tearDown() = PublicKeyRegistry.clearForTest()

    private fun post(author: String, n: Int) = FeedNote.fromEvent(
        id = n.toString().padStart(64, '0'), pubkey = author, content = "a post about something $n",
        tags = emptyList(), createdAt = 1_700_000_000L + n, kind = 1, verify = { true },
    )

    private fun discover(notes: List<FeedNote>) = FeedFilterEngine.filterFeedNotes(
        notes, FeedMode.DISCOVERY, emptySet(), showReposts = true, showReplies = true,
        followedPubkeys = setOf(pk('b')), wotPubkeys = setOf(pk('b'), friendOfFriend, leaked),
    ).map { it.pubkey }

    @Test fun `a web member whose key is public stays out of Discover`() {
        val notes = listOf(post(friendOfFriend, 1), post(leaked, 2))
        assertEquals("both in the web, neither public yet", setOf(friendOfFriend, leaked), discover(notes).toSet())
        val nsec = HavenBridge.encodeNsec("0".repeat(63) + "3")!!
        PublicKeyRegistry.noteText("my key: $nsec") { leaked }
        assertEquals(listOf(friendOfFriend), discover(notes))
    }
}
