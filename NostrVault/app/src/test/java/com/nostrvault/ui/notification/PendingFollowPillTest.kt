package com.nostrvault.ui.notification

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** A follow queued until the list loads: one pill, pending, then its outcome (iOS FollowNotificationManager). */
@OptIn(ExperimentalCoroutinesApi::class)
class PendingFollowPillTest {

    @Before fun setUp() = Dispatchers.setMain(StandardTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    private fun NotificationManager.follows() = notifications.value.filterIsInstance<FollowNotification>()

    @Test fun pendingTurnsIntoTheOutcomeInPlace() {
        val manager = NotificationManager()
        manager.addPendingFollow("a", "Alice", follow = true)
        val pill = manager.follows().single()
        assertEquals(FollowKind.PENDING(follow = true), pill.kind)
        assertEquals(0L, pill.autoDismissMs)

        manager.showFollow("Alice", FollowKind.FOLLOWED, pubkey = "a")
        val after = manager.follows().single()
        assertEquals(pill.id, after.id)
        assertEquals(FollowKind.FOLLOWED, after.kind)
    }

    @Test fun aSecondTapUpdatesTheSamePill() {
        val manager = NotificationManager()
        manager.addPendingFollow("a", "Alice", follow = true)
        manager.addPendingFollow("a", "Alice", follow = false)
        assertEquals(FollowKind.PENDING(follow = false), manager.follows().single().kind)
    }

    @Test fun anOutcomeForSomeoneElseIsItsOwnPill() {
        val manager = NotificationManager()
        manager.addPendingFollow("a", "Alice", follow = true)
        manager.showFollow("Bob", FollowKind.FOLLOWED, pubkey = "b")
        assertEquals(2, manager.follows().size)
    }

    @Test fun droppedAndClearedPillsGo() {
        val manager = NotificationManager()
        manager.addPendingFollow("a", "Alice", follow = true)
        manager.addPendingFollow("b", "Bob", follow = false)
        manager.dismissPendingFollow("a")
        assertEquals(listOf("b"), manager.follows().map { it.pubkey })
        manager.clearPendingFollows()
        assertTrue(manager.follows().isEmpty())
    }
}
