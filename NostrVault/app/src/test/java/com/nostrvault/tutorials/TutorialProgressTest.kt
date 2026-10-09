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

    @Test fun fillYourVaultStartsFirstAndAloneOnScreen() {
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

    /** Skipping counts the same as finishing for the gate, and every page
     *  still starts its own tutorial in the same launch, one at a time. */
    @Test fun eachPageStartsItsTutorialInTheSameLaunch() {
        val p = TutorialProgress(MemoryStore())
        p.startIfEligible(TutorialID.FILL_YOUR_VAULT, alice)
        p.skip(TutorialID.FILL_YOUR_VAULT, alice)
        assertNull(p.active)
        assertTrue(p.startIfEligible(TutorialID.FEEDS, alice))
        assertFalse(p.startIfEligible(TutorialID.VAULT, alice))

        p.skip(TutorialID.FEEDS, alice)
        assertTrue(p.startIfEligible(TutorialID.VAULT, alice))
        assertEquals(TutorialID.VAULT, p.active)
    }

    /** Fill your vault's "built" card is up after it's done: nothing starts
     *  over it until it's put away. */
    @Test fun heldStopsPageTutorials() {
        val p = TutorialProgress(MemoryStore())
        p.startIfEligible(TutorialID.FILL_YOUR_VAULT, alice)
        p.finish(TutorialID.FILL_YOUR_VAULT, alice)
        p.held = true
        assertFalse(p.startIfEligible(TutorialID.FEEDS, alice))

        p.held = false
        assertTrue(p.startIfEligible(TutorialID.FEEDS, alice))
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

    @Test fun replayKeepsStatus() {
        val p = TutorialProgress(MemoryStore())
        p.finish(TutorialID.FEEDS, alice)
        p.replay(TutorialID.FEEDS)
        assertEquals(TutorialID.FEEDS, p.active)
        assertEquals(TutorialStatus.DONE, p.status(TutorialID.FEEDS, alice))
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

    @Test fun feedsCardsPointAtTheTwoCorners() {
        assertEquals(
            listOf(TutorialContent.FEED_PICKER, TutorialContent.FEED_TOOLBAR, TutorialContent.FEED_TOOLBAR),
            TutorialContent.feeds.map { it.anchor },
        )
    }

    /** Pocket Relay points at the relay card, its activity, then its address. */
    @Test fun pocketRelayCardsPointAtTheDashboard() {
        assertEquals(
            listOf(TutorialContent.RELAY_STATUS, TutorialContent.RELAY_ACTIVITY, TutorialContent.RELAY_ADDRESS),
            TutorialContent.pocketRelay.map { it.anchor },
        )
    }

    /** The screens put these on with `Modifier.tutorialAnchor`, and iOS uses
     *  the same names. A typo here leaves a card with no pointer. */
    @Test fun anchorNamesMatchIos() {
        assertEquals("feeds.picker", TutorialContent.FEED_PICKER)
        assertEquals("feeds.toolbar", TutorialContent.FEED_TOOLBAR)
        assertEquals("vault.modes", TutorialContent.VAULT_MODES)
        assertEquals("vault.filters", TutorialContent.VAULT_FILTERS)
        assertEquals("vault.relay", TutorialContent.VAULT_RELAY)
        assertEquals("wallet.empty", TutorialContent.WALLET_EMPTY)
        assertEquals("wallet.connect", TutorialContent.WALLET_CONNECT_BUTTON)
        assertEquals("relay.status", TutorialContent.RELAY_STATUS)
        assertEquals("relay.address", TutorialContent.RELAY_ADDRESS)
        assertEquals("relay.activity", TutorialContent.RELAY_ACTIVITY)
    }

    /** Every tutorial has cards on Android now (iOS: the iPhone/iPad build). */
    @Test fun everyTutorialIsAvailable() {
        TutorialID.entries.forEach { assertTrue(it.name, it.isAvailable) }
        listOf(TutorialID.FEEDS, TutorialID.VAULT, TutorialID.WALLET_CONNECT, TutorialID.POCKET_RELAY).forEach {
            assertEquals(it.name, 3, it.steps.size)
        }
        assertTrue(TutorialID.FILL_YOUR_VAULT.steps.isEmpty()) // its guide is FillYourFeedOverlay
    }

    /** The "Next: …" chain, in the iOS order. */
    @Test fun nextFollowsTheIosOrder() {
        assertEquals(TutorialID.FEEDS, TutorialID.FILL_YOUR_VAULT.next)
        assertEquals(TutorialID.VAULT, TutorialID.FEEDS.next)
        assertEquals(TutorialID.WALLET_CONNECT, TutorialID.VAULT.next)
        assertEquals(TutorialID.POCKET_RELAY, TutorialID.WALLET_CONNECT.next)
        assertNull(TutorialID.POCKET_RELAY.next)
        assertNull(TutorialID.IMPORT_TOUR.next)
    }

    @Test fun importTourCoversVaultAndPocketRelay() {
        val progress = TutorialProgress(MemoryStore())
        progress.skip(TutorialID.IMPORT_TOUR, alice)
        assertEquals(TutorialStatus.NOT_STARTED, progress.status(TutorialID.VAULT, alice))

        progress.finish(TutorialID.IMPORT_TOUR, alice)
        assertEquals(TutorialStatus.DONE, progress.status(TutorialID.VAULT, alice))
        assertEquals(TutorialStatus.DONE, progress.status(TutorialID.POCKET_RELAY, alice))
    }

    /** Covering never overwrites a status someone already chose. */
    @Test fun coverKeepsAnEarlierSkip() {
        val progress = TutorialProgress(MemoryStore())
        progress.skip(TutorialID.VAULT, alice)
        progress.finish(TutorialID.IMPORT_TOUR, alice)
        assertEquals(TutorialStatus.SKIPPED, progress.status(TutorialID.VAULT, alice))
    }

    /** The import tour runs in setup, before Fill your vault has a say. */
    @Test fun importTourDoesNotWaitForFillYourVault() {
        assertTrue(TutorialProgress(MemoryStore()).startIfEligible(TutorialID.IMPORT_TOUR, alice))
    }

    @Test fun importTourKey() {
        assertEquals("tutorial.import-tour", TutorialProgress.key(TutorialID.IMPORT_TOUR, alice))
        assertEquals(5, TutorialContent.importTour.size)
        assertTrue(TutorialContent.importTour.all { it.anchor == null })
        assertTrue(TutorialID.IMPORT_TOUR.isAvailable)
    }
}
