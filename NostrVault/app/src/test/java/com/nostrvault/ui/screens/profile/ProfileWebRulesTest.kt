package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The profile page's outside-web rules (PROFILE_WOT_LEAKS.md 1-4, 6). */
class ProfileWebRulesTest {
    private val owner = "a".repeat(64)
    private val friend = "f".repeat(64)
    private val stranger = "e".repeat(64)
    private val me = "c".repeat(64)

    private fun note(id: Char, pubkey: String, kind: Int = 1, repostedBy: String? = null) = FeedNote.fromEvent(
        id = id.toString().repeat(64), pubkey = pubkey, content = "x", tags = emptyList(),
        createdAt = 1_700_000_000L, kind = kind, repostedBy = repostedBy, verify = { true },
    )

    @Test
    fun ownNotesAndOwnRepostsBelongButOthersRepostsOfTheirNoteDoNot() {
        assertTrue(ProfileWebRules.belongsTo(note('1', owner), owner))
        assertTrue(ProfileWebRules.belongsTo(note('2', friend, repostedBy = owner), owner))
        assertFalse(ProfileWebRules.belongsTo(note('3', owner, repostedBy = stranger), owner))
        assertFalse(ProfileWebRules.belongsTo(note('4', friend), owner))
    }

    @Test
    fun taggedJudgesTheAuthorAndForARepostTheReposterToo() {
        val web = setOf(friend)
        val always = setOf(me)
        assertTrue(ProfileWebRules.allowsTagged(note('1', friend), web, always))
        assertFalse(ProfileWebRules.allowsTagged(note('2', stranger), web, always))
        // A stranger's repost of a friend's note: the stranger brings it in.
        assertFalse(ProfileWebRules.allowsTagged(note('3', friend, repostedBy = stranger), web, always))
        assertTrue(ProfileWebRules.allowsTagged(note('4', friend, repostedBy = friend), web, always))
        assertTrue(ProfileWebRules.allowsTagged(note('5', me), web, always))
    }

    @Test
    fun taggedFailsClosedOnAnEmptyWeb() {
        assertFalse(ProfileWebRules.allowsTagged(note('1', friend), emptySet(), setOf(me)))
        assertTrue(ProfileWebRules.allowsTagged(note('2', me), emptySet(), setOf(me)))
    }

    @Test
    fun repostsOfBlockedPeopleAreLeftOutButTheOwnerIsExempt() {
        val own = note('1', owner)
        val ofBlocked = note('2', stranger, repostedBy = owner)
        val ofFriend = note('3', friend, repostedBy = owner)
        val notes = listOf(own, ofBlocked, ofFriend)
        assertEquals(listOf(own, ofFriend), ProfileWebRules.withoutBlockedReposts(notes, setOf(stranger), owner))
        // Viewing a blocked person's own profile still lists their own notes and reposts.
        assertEquals(notes, ProfileWebRules.withoutBlockedReposts(notes, setOf(owner), owner))
    }

    @Test
    fun followersCountOnlyTheWebAndOncePerPerson() {
        val outside = { pk: String -> pk == stranger }
        assertEquals(2, ProfileWebRules.followersInWeb(listOf(friend), listOf(friend, me, stranger), outside, webLoaded = true))
        assertNull(ProfileWebRules.followersInWeb(listOf(friend), listOf(friend), outside, webLoaded = false))
    }
}
