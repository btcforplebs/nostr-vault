package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import org.junit.Assert.assertEquals
import org.junit.Test

/** Search never shows someone you blocked, and keeps showing everyone else. */
class SearchBlockFilterTest {

    private val friend = "f".repeat(64)
    private val troll = "b".repeat(64)
    private val blocked = setOf(troll)

    private fun note(id: String, pubkey: String, repostedBy: String? = null) =
        FeedNote.fromEvent(id, pubkey, "Sunset at the pier", emptyList(), 1_700_000_000L, 1, repostedBy)

    private val results = GlobalSearchResults(
        profiles = listOf(FeedProfile(pubkey = troll), FeedProfile(pubkey = friend)),
        notes = listOf(
            note("1".repeat(64), troll),
            note("2".repeat(64), friend, repostedBy = troll),
            note("3".repeat(64), friend),
        ),
    )

    @Test fun `blocked profile and notes that show them are dropped, friend stays`() {
        val out = SearchBlockFilter.apply(results, blocked)
        assertEquals(listOf(friend), out.profiles.map { it.pubkey })
        assertEquals(listOf("3".repeat(64)), out.notes.map { it.id })
    }

    @Test fun `reply under a blocked author's post is dropped when the parent is known`() {
        val parent = note("4".repeat(64), troll)
        val reply = FeedNote.fromEvent("5".repeat(64), friend, "agreed",
            listOf(listOf("e", parent.id, "", "reply")), 1_700_000_001L, 1, null)
        val out = SearchBlockFilter.apply(GlobalSearchResults(notes = listOf(reply)), blocked) {
            if (it == parent.id) troll else null
        }
        assertEquals(emptyList<FeedNote>(), out.notes)
    }

    @Test fun `no blocks returns everything`() {
        assertEquals(results, SearchBlockFilter.apply(results, emptySet()))
    }

    @Test fun `suggested candidates drop blocked and keep order`() {
        assertEquals(listOf("a", "c"), SearchBlockFilter.visiblePubkeys(listOf("a", troll, "c"), blocked))
    }
}
