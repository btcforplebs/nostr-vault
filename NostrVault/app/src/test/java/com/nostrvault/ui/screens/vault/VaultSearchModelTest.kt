package com.nostrvault.ui.screens.vault

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.VaultSearchLogic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

/** [VaultSearchModel.sectionsFor]: what the Vault's search shows for the profiles and notes a walk matched. */
class VaultSearchModelTest {
    // Made-up keys.
    private val alice = "a1".repeat(32)
    private val bob = "b2".repeat(32)
    private val carol = "c3".repeat(32)
    private val mallory = "d4".repeat(32)
    private val fakeNpub = "npub1fakeforthistestonly"

    /** Stands in for `HavenBridge.decodeNpub`: only [fakeNpub] decodes, to [carol]. */
    private val decodeNpub: (String) -> String? = mapOf(fakeNpub to carol)::get

    private fun note(
        id: String,
        pubkey: String = alice,
        content: String = "hello",
        createdAt: Long = 1_000,
        kind: Int = 1,
        tags: List<List<String>> = emptyList(),
    ) = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)

    private fun sections(
        query: String,
        profiles: List<FeedProfile> = emptyList(),
        found: List<FeedNote> = emptyList(),
        cached: Map<String, FeedProfile> = emptyMap(),
        blocked: Set<String> = emptySet(),
        follows: Set<String> = emptySet(),
        authorOf: (String) -> String? = { null },
    ) = VaultSearchModel.sectionsFor(query, profiles, found, cached, blocked, follows, decodeNpub, authorOf)

    @Test
    fun aProfileMatchedOnlyThroughItsHexIsDropped() {
        // alice's hex is "a1a1…": no "ab" in it either, so use a key that has one.
        val abKey = "ab".repeat(32)
        val r = sections("ab", profiles = listOf(FeedProfile(abKey, name = "Zed"), FeedProfile(bob, name = "Abby")))
        assertEquals(listOf(bob), r.people.map { it.pubkey })
    }

    @Test
    fun aKeyQueryKeepsExactlyThatPerson() {
        val r = sections(
            alice,
            profiles = listOf(FeedProfile(alice, name = "Alice"), FeedProfile(bob, name = alice)),
        )
        assertEquals(listOf(alice), r.people.map { it.pubkey })
    }

    @Test
    fun aPastedNpubWithNoStoredProfileGivesABareRow() {
        val r = sections(fakeNpub)
        assertEquals(listOf(FeedProfile(pubkey = carol)), r.people)
    }

    @Test
    fun aPastedNpubUsesTheCachedProfileWhenThereIsOne() {
        val stored = FeedProfile(carol, name = "Carol")
        val r = sections("nostr:$fakeNpub", cached = mapOf(carol to stored))
        assertEquals(listOf(stored), r.people)
    }

    @Test
    fun bareHexGivesARowOnlyWhenAProfileIsCached() {
        assertTrue(sections(carol).people.isEmpty())
        val stored = FeedProfile(carol, name = "Carol")
        assertEquals(listOf(stored), sections(carol, cached = mapOf(carol to stored)).people)
    }

    @Test
    fun blockedPeopleAndTheirNotesAreRemoved() {
        val parent = "e".repeat(64)
        val r = sections(
            "hello",
            profiles = listOf(FeedProfile(alice, name = "hello alice"), FeedProfile(mallory, name = "hello mallory")),
            found = listOf(
                note("1".repeat(64), pubkey = alice),
                note("2".repeat(64), pubkey = mallory),
                note("3".repeat(64), pubkey = bob, tags = listOf(listOf("e", parent, "", "reply"))),
            ),
            blocked = setOf(mallory),
            authorOf = { if (it == parent) mallory else null },
        )
        assertEquals(listOf(alice), r.people.map { it.pubkey })
        assertEquals(listOf("1".repeat(64)), r.notes.map { it.id })
    }

    @Test
    fun followsComeFirstThenByNameCaseInsensitive() {
        val r = sections(
            "pal",
            profiles = listOf(
                FeedProfile(alice, name = "zed pal"),
                FeedProfile(bob, name = "Bea pal"),
                FeedProfile(carol, name = "amy pal"),
                FeedProfile(mallory, name = "Yan pal"),
            ),
            follows = setOf(alice, mallory),
        )
        assertEquals(listOf("Yan pal", "zed pal", "amy pal", "Bea pal"), r.people.map { it.bestName })
    }

    @Test
    fun notesComeOutNewestFirst() {
        val r = sections(
            "hello",
            found = listOf(note("1".repeat(64), createdAt = 100), note("2".repeat(64), createdAt = 300), note("3".repeat(64), createdAt = 200)),
        )
        assertEquals(listOf("2".repeat(64), "3".repeat(64), "1".repeat(64)), r.notes.map { it.id })
    }

    @Test
    fun kindsOutsideNoteKindsAreDropped() {
        assertTrue(6 !in VaultSearchLogic.NOTE_KINDS && 7 !in VaultSearchLogic.NOTE_KINDS)
        val r = sections(
            "hello",
            found = listOf(
                note("1".repeat(64), kind = 1),
                note("6".repeat(64), kind = 6),
                note("7".repeat(64), kind = 7),
                note("a".repeat(64), kind = 30023),
                note("b".repeat(64), kind = 20),
            ),
        )
        assertEquals(setOf("1".repeat(64), "a".repeat(64), "b".repeat(64)), r.notes.map { it.id }.toSet())
    }

    @Test
    fun hashtagsAndLinksComeFromTheKeptNotesOnly() {
        val kept = note("1".repeat(64), pubkey = alice, content = "hello #nostrkept https://kept.example/a", createdAt = 100)
        val blockedNote = note("2".repeat(64), pubkey = mallory, content = "hello #nostrblocked https://blocked.example/b", createdAt = 200)
        val reaction = note("3".repeat(64), pubkey = bob, content = "hello #nostrreaction https://reaction.example/c", createdAt = 300, kind = 7)
        val r = sections("hello nostr", found = listOf(kept, blockedNote, reaction), blocked = setOf(mallory))
        assertEquals(listOf("nostrkept"), r.hashtags)
        assertEquals(listOf("https://kept.example/a"), r.links.map { it.url })
        assertEquals(listOf("1".repeat(64)), r.links.map { it.noteId })
    }

    /** A walk that did not reach its end never reads as everything (Tron, PR 740). */
    @Test
    fun aWalkThatDidNotFinishIsCutShort() {
        assertEquals(VaultSearchLogic.Status.SEARCHING, VaultSearchModel.statusOf(isRunning = true, incomplete = true))
        assertEquals(VaultSearchLogic.Status.DONE, VaultSearchModel.statusOf(isRunning = false, incomplete = false))
        assertEquals(VaultSearchLogic.Status.CUT_SHORT, VaultSearchModel.statusOf(isRunning = false, incomplete = true))
        // A dropped socket or a CLOSED is as incomplete as a timeout; a clean end is not.
        assertTrue(com.nostrvault.service.GlobalSearchSession.isIncomplete(timedOut = true, error = null, closedReason = null))
        assertTrue(com.nostrvault.service.GlobalSearchSession.isIncomplete(timedOut = false, error = "connection closed", closedReason = null))
        assertTrue(com.nostrvault.service.GlobalSearchSession.isIncomplete(timedOut = false, error = null, closedReason = "auth-required: x"))
        assertFalse(com.nostrvault.service.GlobalSearchSession.isIncomplete(timedOut = false, error = null, closedReason = null))
    }

}
