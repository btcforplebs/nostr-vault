package com.nostrvault.tutorials

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as iOS `TutorialProgressTests`, so the two apps keep one set of rules. */
class TutorialProgressTest {
    private class MemoryStore : TutorialStore {
        val values = mutableMapOf<String, String>()
        override fun getString(key: String) = values[key]
        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    @Test fun fillYourVaultStartsFirstAndBlocksOthers() {
        val p = TutorialProgress(MemoryStore())
        assertTrue(p.startIfEligible(TutorialID.FILL_YOUR_VAULT, alice))
        assertFalse(p.startIfEligible(TutorialID.FEEDS, alice))
        assertEquals(TutorialID.FILL_YOUR_VAULT, p.active)
    }

    @Test fun pageTutorialsWaitForFillYourVault() {
        val p = TutorialProgress(MemoryStore())
        assertFalse(p.startIfEligible(TutorialID.FEEDS, alice))
        assertNull(p.active)
    }

    @Test fun oneTutorialPerLaunch() {
        val store = MemoryStore()
        val p = TutorialProgress(store)
        p.startIfEligible(TutorialID.FILL_YOUR_VAULT, alice)
        p.skip(TutorialID.FILL_YOUR_VAULT, alice)
        assertNull(p.active)
        assertFalse(p.startIfEligible(TutorialID.FEEDS, alice))
        assertTrue(TutorialProgress(store).startIfEligible(TutorialID.FEEDS, alice))
    }

    @Test fun finishedNeverStartsAgainOnItsOwn() {
        val store = MemoryStore()
        val p = TutorialProgress(store)
        p.startIfEligible(TutorialID.FILL_YOUR_VAULT, alice)
        p.finish(TutorialID.FILL_YOUR_VAULT, alice)
        assertEquals(TutorialStatus.DONE, p.status(TutorialID.FILL_YOUR_VAULT, alice))
        assertFalse(TutorialProgress(store).startIfEligible(TutorialID.FILL_YOUR_VAULT, alice))
    }

    @Test fun scopes() {
        val store = MemoryStore()
        val p = TutorialProgress(store)
        p.finish(TutorialID.FILL_YOUR_VAULT, alice)
        p.finish(TutorialID.FEEDS, alice)
        assertEquals(TutorialStatus.NOT_STARTED, p.status(TutorialID.FILL_YOUR_VAULT, bob))
        assertEquals(TutorialStatus.DONE, p.status(TutorialID.FEEDS, bob))
        assertTrue(TutorialProgress(store).startIfEligible(TutorialID.FILL_YOUR_VAULT, bob))
    }

    @Test fun replayKeepsStatusAndDoesNotUseTheLaunch() {
        val p = TutorialProgress(MemoryStore())
        p.finish(TutorialID.FEEDS, alice)
        p.replay(TutorialID.FEEDS)
        assertEquals(TutorialID.FEEDS, p.active)
        assertEquals(TutorialStatus.DONE, p.status(TutorialID.FEEDS, alice))
        assertFalse(p.autoStartedThisLaunch)
    }

    @Test fun resetAll() {
        val p = TutorialProgress(MemoryStore())
        p.finish(TutorialID.FILL_YOUR_VAULT, alice)
        p.skip(TutorialID.FEEDS, alice)
        p.resetAll(alice)
        assertTrue(TutorialID.entries.all { p.status(it, alice) == TutorialStatus.NOT_STARTED })
    }

    @Test fun noAccountDoesNothing() {
        val store = MemoryStore()
        val p = TutorialProgress(store)
        assertFalse(p.startIfEligible(TutorialID.FILL_YOUR_VAULT, ""))
        p.finish(TutorialID.FEEDS, "")
        assertTrue(store.values.isEmpty())
    }

    @Test fun otherVersionsReadAsNotStarted() {
        val store = MemoryStore()
        val p = TutorialProgress(store)
        val key = TutorialProgress.key(TutorialID.FEEDS, alice)
        store.values[key] = "done@${TutorialID.FEEDS.version}"
        assertEquals(TutorialStatus.DONE, p.status(TutorialID.FEEDS, alice))
        store.values[key] = "done@${TutorialID.FEEDS.version + 1}"
        assertEquals(TutorialStatus.NOT_STARTED, p.status(TutorialID.FEEDS, alice))
        store.values[key] = "done"
        assertEquals(TutorialStatus.NOT_STARTED, p.status(TutorialID.FEEDS, alice))
    }

    /** Same keys and values as iOS. */
    @Test fun storageKeysMatchIos() {
        assertEquals("tutorial.fill-your-vault.$alice", TutorialProgress.key(TutorialID.FILL_YOUR_VAULT, alice))
        assertEquals("tutorial.feeds", TutorialProgress.key(TutorialID.FEEDS, alice))
        assertEquals("tutorial.wallet-connect", TutorialProgress.key(TutorialID.WALLET_CONNECT, alice))
        assertEquals("tutorial.pocket-relay", TutorialProgress.key(TutorialID.POCKET_RELAY, alice))
    }

    @Test fun feedsCardsPointAtThePicker() {
        assertEquals(6, TutorialContent.feeds.size)
        assertTrue(TutorialContent.feeds.all { it.anchor == TutorialContent.FEED_PICKER })
        assertTrue(TutorialID.FILL_YOUR_VAULT.isAvailable) // its guide is FillYourFeedOverlay
        assertTrue(TutorialID.FEEDS.isAvailable)
    }
}
