package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A follow or unfollow the relays refused snaps back, and the user is told
 * which one failed and that another tap may work, never a silent snap-back
 * (iOS: Tao's Sam-sim unfollow, 2026-10-12).
 */
class FollowRollbackTest {
    private val before = listOf("a", "b", "jack")
    private val unfollowed = listOf("a", "b")

    @Test fun `a refused unfollow puts the follow back`() {
        assertEquals(before, followRollback(current = unfollowed, published = unfollowed, rollback = before))
    }

    @Test fun `a newer edit since the refused one is left alone`() {
        assertNull(followRollback(current = listOf("a"), published = unfollowed, rollback = before))
        assertNull(followRollback(current = unfollowed, published = unfollowed, rollback = null))
    }

    @Test fun `the pill says which one failed and to try again`() {
        assertEquals("Couldn't unfollow, try again", followFailedMessage(follow = false))
        assertEquals("Couldn't follow, try again", followFailedMessage(follow = true))
    }
}
