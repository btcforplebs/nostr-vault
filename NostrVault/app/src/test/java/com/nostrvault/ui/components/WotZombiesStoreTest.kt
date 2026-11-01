package com.nostrvault.ui.components

import com.nostrvault.data.model.WotZombies
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** My Web's zombie store: polls while the vault checks, forces once, keeps accounts apart. */
@OptIn(ExperimentalCoroutinesApi::class)
class WotZombiesStoreTest {
    private val me = "a".repeat(64)
    private val other = "b".repeat(64)
    private fun report(owner: String, vararg pubkeys: String) = WotZombies.Report(
        owner = owner, follows = 10,
        zombies = pubkeys.map { WotZombies.Zombie(it, 0, 400, WotZombies.Bucket.ANCIENT) },
    )
    private val defaultRead = WotZombiesStore.read
    private val defaultIo = WotZombiesStore.io

    @After fun tearDown() {
        WotZombiesStore.resetForTest()
        WotZombiesStore.read = defaultRead
        WotZombiesStore.io = defaultIo
    }

    @Test fun pollsUntilTheCheckEndsAndForcesOnlyTheFirstRead() = runTest {
        WotZombiesStore.io = StandardTestDispatcher(testScheduler)
        val calls = mutableListOf<Boolean>()
        WotZombiesStore.read = { _, force ->
            calls += force
            if (calls.size < 3) WotZombies.State(checking = true) else WotZombies.State(report = report(me, "1".repeat(64)))
        }
        WotZombiesStore.load(this, me, force = true)
        advanceUntilIdle()
        assertEquals(listOf(true, false, false), calls)
        assertFalse(WotZombiesStore.checking)
        assertEquals(1, WotZombiesStore.report(emptySet())?.zombies?.size)
    }

    /** Someone unfollowed in Plebs vs. Zombies drops off without a new check. */
    @Test fun reportKeepsOnlyPeopleStillFollowed() = runTest {
        WotZombiesStore.io = StandardTestDispatcher(testScheduler)
        val one = "1".repeat(64)
        val two = "2".repeat(64)
        WotZombiesStore.read = { _, _ -> WotZombies.State(report = report(me, one, two)) }
        WotZombiesStore.load(this, me)
        advanceUntilIdle()
        assertEquals(listOf(two), WotZombiesStore.report(setOf(two, "3".repeat(64)))?.zombies?.map { it.pubkey })
        assertEquals(9, WotZombiesStore.report(setOf(two))?.follows)
    }

    /** A report for one account never shows on another's card. */
    @Test fun switchingAccountsClearsTheOldReport() = runTest {
        WotZombiesStore.io = StandardTestDispatcher(testScheduler)
        WotZombiesStore.read = { owner, _ -> if (owner == me) WotZombies.State(report = report(me, "1".repeat(64))) else null }
        WotZombiesStore.load(this, me)
        advanceUntilIdle()
        WotZombiesStore.load(this, other)
        advanceUntilIdle()
        assertNull(WotZombiesStore.report(emptySet()))
    }
}
