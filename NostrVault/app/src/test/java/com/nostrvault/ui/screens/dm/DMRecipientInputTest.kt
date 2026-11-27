package com.nostrvault.ui.screens.dm

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** NV_MESSAGES_UX_CHECK 2026-11-18, B2 and B3 on Android: what New Message's "To:" accepts. */
class DMRecipientInputTest {
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val stranger = "c".repeat(64)
    private val profiles = mapOf(
        alice to FeedProfile(pubkey = alice, name = "Alice"),
        bob to FeedProfile(pubkey = bob, name = "Bob"),
    )

    @Test fun `an npub, an nprofile and a hex key all name someone, loaded or not`() {
        val npub = HavenBridge.encodeNpub(stranger)!!
        val nprofile = HavenBridge.encodeNprofile(stranger, listOf("wss://relay.example"))!!
        assertEquals(stranger, DMRecipientInput.key(npub))
        assertEquals(stranger, DMRecipientInput.key("nostr:$npub"))
        assertEquals(stranger, DMRecipientInput.key(nprofile))
        assertEquals(stranger, DMRecipientInput.key("  ${stranger.uppercase()} "))
        assertEquals(listOf(stranger), DMRecipientInput.results(nprofile, profiles, emptySet()))
        assertNull("a name is searched for, not decoded", DMRecipientInput.key("Alice"))
    }

    @Test fun `a name searches the loaded profiles`() {
        assertEquals(listOf(alice), DMRecipientInput.results("ali", profiles, emptySet()))
        assertEquals(emptyList<String>(), DMRecipientInput.results("a", profiles, emptySet()))
    }

    @Test fun `blocked people never show, by name or by key`() {
        val blocked = setOf(alice)
        assertEquals(emptyList<String>(), DMRecipientInput.results("ali", profiles, blocked))
        assertEquals(emptyList<String>(), DMRecipientInput.results(HavenBridge.encodeNpub(alice)!!, profiles, blocked))
        assertEquals(listOf(bob), DMRecipientInput.results("bob", profiles, blocked))
    }

    @Test fun `no match says how to reach someone, never a blank card`() {
        assertTrue(DMRecipientInput.showsNoMatch("zed", emptyList()))
        assertFalse(DMRecipientInput.showsNoMatch("z", emptyList()))
        assertFalse(DMRecipientInput.showsNoMatch("ali", listOf(alice)))
    }

    /** D5: the shared people order, follows first, then the best name match, capped at MAX_RESULTS. */
    @Test fun `names are ranked follows first, then exact before contains`() {
        val ann = "1".repeat(64); val joanne = "2".repeat(64); val annie = "3".repeat(64)
        val people = mapOf(
            ann to FeedProfile(pubkey = ann, name = "ann"),
            joanne to FeedProfile(pubkey = joanne, name = "Joanne"),
            annie to FeedProfile(pubkey = annie, name = "Annie"),
        )
        assertEquals(listOf(ann, annie, joanne), DMRecipientInput.results("ann", people, emptySet()))
        val circle = com.nostrvault.data.model.PeopleSearchRank.Circle(emptySet(), setOf(joanne), emptySet())
        assertEquals(listOf(joanne, ann, annie), DMRecipientInput.results("ann", people, emptySet(), circle))
        val many = (10..30).associate { n -> "%064d".format(n) to FeedProfile(pubkey = "%064d".format(n), name = "sam $n") }
        assertEquals(DMRecipientInput.MAX_RESULTS, DMRecipientInput.results("sam", many, emptySet()).size)
    }
}
