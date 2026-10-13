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

    @Test fun `an account with no key is told it is read-only, not to try again`() {
        assertEquals(true, isReadOnlySigning("local", hasLocalKey = false))
        assertEquals(true, isReadOnlySigning("browse", hasLocalKey = false))
        assertEquals(false, isReadOnlySigning("local", hasLocalKey = true))
        // Amber and bunkers sign off the phone: no local key needed.
        assertEquals(false, isReadOnlySigning("amber", hasLocalKey = false))
        assertEquals(false, isReadOnlySigning("nip46", hasLocalKey = false))
        assertEquals("This account is read-only. Add its key to follow.", readOnlyFollowMessage(follow = true))
        assertEquals("This account is read-only. Add its key to unfollow.", readOnlyFollowMessage(follow = false))
    }

    @Test fun `one deliberate unfollow may empty or halve a list that loaded`() {
        val me = "m".repeat(64)
        val last = ContactManager.prepareUnfollow("a", me, listOf(listOf("p", "a")), listOf("a"),
            hasAttemptedLoad = true, isLoading = false, listConfirmed = true)
        assertEquals(emptyList<String>(), last.getOrThrow().pubkeys)
        val half = ContactManager.prepareUnfollow("a", me, listOf(listOf("p", "a"), listOf("p", "b")), listOf("a", "b"),
            hasAttemptedLoad = true, isLoading = false, listConfirmed = true)
        assertEquals(listOf("b"), half.getOrThrow().pubkeys)
    }
}
