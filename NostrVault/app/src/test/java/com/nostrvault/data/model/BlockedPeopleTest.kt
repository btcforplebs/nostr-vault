package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A block on DMs: the opened message's real sender is checked, conversations
 * with a blocked person are hidden (not deleted), and they never alert.
 */
class BlockedPeopleTest {
    private val blockedHex = "b".repeat(64)
    private val friendHex = "f".repeat(64)

    private data class Convo(val id: String)

    @Test
    fun conversationWithBlockedPersonIsHidden() {
        val all = listOf(Convo(friendHex), Convo(blockedHex))
        assertEquals(listOf(friendHex), BlockedPeople.visibleConversations(all, setOf(blockedHex)) { it.id }.map { it.id })
    }

    /** Unblocking is just an empty block list: nothing was removed, so it shows again. */
    @Test
    fun unblockShowsTheConversationAgain() {
        val all = listOf(Convo(friendHex), Convo(blockedHex))
        assertEquals(all, BlockedPeople.visibleConversations(all, emptySet()) { it.id })
    }

    @Test
    fun blockedSenderNeverAlerts() {
        assertFalse(BlockedPeople.mayAlert(blockedHex, isFromMe = false, blocked = setOf(blockedHex)))
    }

    /** Positive control: the same message from someone not blocked does. */
    @Test
    fun unblockedSenderAlerts() {
        assertTrue(BlockedPeople.mayAlert(friendHex, isFromMe = false, blocked = setOf(blockedHex)))
    }

    @Test
    fun ownCopyNeverAlerts() {
        assertFalse(BlockedPeople.mayAlert(friendHex, isFromMe = true, blocked = emptySet()))
    }

    /** Block lists hold lowercase hex; a sender in upper case is still caught. */
    @Test
    fun senderCaseDoesNotEscapeTheBlock() {
        assertTrue(BlockedPeople.isBlocked(blockedHex.uppercase(), setOf(blockedHex)))
        assertFalse(BlockedPeople.isBlocked("", setOf(blockedHex)))
    }

    private val owner = "npub1owner"
    private val second = "npub1second"
    private val alice = "npub1alice"
    private val bob = "npub1bob"

    /** Saved and loaded the way ConfigStore does, as after a relaunch. */
    private fun relaunch(cfg: HavenConfig): HavenConfig {
        val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
        return json.decodeFromString(json.encodeToString(cfg))
    }

    /**
     * The owner's only block lives in the legacy list. Unblocking it empties
     * the page and the relay's blacklist, and stays that way after a relaunch.
     */
    @Test
    fun unblockingTheLastLegacyBlockClearsItForTheRelay() {
        val cfg = HavenConfig(ownerNpub = owner, blockedNpubs = listOf(alice))
        assertEquals(listOf(alice), cfg.blockedForActiveAccount())

        val after = relaunch(BlockedPeople.unblock(cfg, alice))
        assertEquals(emptyList<String>(), after.blockedForActiveAccount())
        assertEquals(emptyList<String>(), after.allBlockedNpubsAcrossAccounts())
    }

    @Test
    fun unblockingOneLegacyBlockKeepsTheOthers() {
        val cfg = HavenConfig(ownerNpub = owner, blockedNpubs = listOf(alice, bob))
        val after = relaunch(BlockedPeople.unblock(cfg, alice))
        assertEquals(listOf(bob), after.blockedForActiveAccount())
        assertEquals(listOf(bob), after.allBlockedNpubsAcrossAccounts())
    }

    @Test
    fun unblockingFromAPerAccountListAlsoClearsTheLegacyCopy() {
        val cfg = HavenConfig(
            ownerNpub = owner,
            blockedNpubs = listOf(alice, bob),
            blockedNpubsPerAccount = mapOf(owner to listOf(alice, bob)),
        )
        val after = BlockedPeople.unblock(cfg, alice)
        assertEquals(listOf(bob), after.blockedForActiveAccount())
        assertEquals(listOf(bob), after.allBlockedNpubsAcrossAccounts())
    }

    /** A second account's unblock leaves the owner's own blocks alone. */
    @Test
    fun secondAccountUnblockLeavesTheOwnersLegacyList() {
        val cfg = HavenConfig(
            ownerNpub = owner,
            accountNpubs = listOf(second),
            activeAccountNpub = second,
            blockedNpubs = listOf(alice),
            blockedNpubsPerAccount = mapOf(second to listOf(alice, bob)),
        )
        val after = BlockedPeople.unblock(cfg, bob)
        assertEquals(listOf(alice), after.blockedForActiveAccount())
        assertEquals(listOf(alice), after.blockedNpubs)
        assertEquals(listOf(alice), after.blockedFor(owner))
    }
}
