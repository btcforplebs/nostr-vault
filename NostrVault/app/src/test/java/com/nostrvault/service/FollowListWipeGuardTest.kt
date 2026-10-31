package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A follow / unfollow must never publish when the user's real follow list is
 * unknown (parity with iOS #180). A tap after a timed-out load used to publish
 * a kind 3 holding only the new follow, replacing every follow everywhere.
 */
class FollowListWipeGuardTest {
    private val someone = "c".repeat(64)
    private val me = "a".repeat(64)

    @Test fun queuedFollowAfterTimeoutPublishesNothing() {
        assertFalse(ContactManager.mayPublishFollowList(hasAttemptedLoad = true, isLoading = false, listConfirmed = false))
        val result = ContactManager.prepareFollow(someone, emptyList(), emptyList(),
            hasAttemptedLoad = true, isLoading = false, listConfirmed = false)
        assertTrue("a follow after a timed-out load must not produce a list, got $result",
            result.exceptionOrNull() is ContactManager.FollowActionError.ListUnavailable)
    }

    @Test fun unfollowAfterTimeoutPublishesNothing() {
        val result = ContactManager.prepareUnfollow(someone, me, listOf(listOf("p", someone)), listOf(someone),
            hasAttemptedLoad = true, isLoading = false, listConfirmed = false)
        assertTrue(result.exceptionOrNull() is ContactManager.FollowActionError.ListUnavailable)
    }

    @Test fun timeoutDoesNotConfirm() {
        assertFalse(ContactManager.loadConfirmsList(foundList = false, relaysAsked = 3, relaysAnswered = 2))
        assertFalse(ContactManager.loadConfirmsList(foundList = false, relaysAsked = 0, relaysAnswered = 0))
    }

    @Test fun everyRelayAnsweringEmptyIsANewAccount() {
        assertTrue(ContactManager.loadConfirmsList(foundList = false, relaysAsked = 2, relaysAnswered = 2))
        val result = ContactManager.prepareFollow(someone, emptyList(), emptyList(),
            hasAttemptedLoad = true, isLoading = false, listConfirmed = true)
        assertEquals(listOf(someone), result.getOrThrow().pubkeys)
    }

    @Test fun duplicateEoseFromOneRelayDoesNotConfirm() {
        val tally = ContactManager.EOSETally()
        tally.sent("contacts-a", "wss://one")
        tally.sent("contacts-b", "wss://two")
        tally.eose("wss://one", "contacts-a")
        tally.eose("wss://one", "contacts-a")
        assertEquals(1, tally.answeredCount())
        assertFalse(ContactManager.loadConfirmsList(false, 2, tally.answeredCount()))
    }

    @Test fun eoseForAnotherSubscriptionIsIgnored() {
        val tally = ContactManager.EOSETally()
        tally.sent("contacts-a", "wss://one")
        tally.eose("wss://one", "other")
        assertEquals(0, tally.answeredCount())
    }

    private fun copy(at: Long, vararg follows: String, owner: String = me) =
        ContactManager.ListCopy(owner, follows.map { listOf("p", it) }, "", at)

    @Test fun oneRelaySayingNoneIsNotAnEmptyList() {
        // Some relays answered "none", others didn't: unknown, refuse to Save.
        assertNull(ContactManager.saveBase(me, fetched = null, confirmedNone = false, freshKey = false, known = null))
        // Every relay answered none, or the key was made here: the list really is empty.
        assertEquals(0, ContactManager.saveBase(me, null, confirmedNone = true, freshKey = false, known = null)!!.tags.size)
        assertEquals(0, ContactManager.saveBase(me, null, confirmedNone = false, freshKey = true, known = null)!!.tags.size)
    }

    @Test fun saveEditsTheNewestCopyNotTheLaunchCopy() {
        val launch = copy(100, "b".repeat(64))
        val elsewhere = copy(200, "b".repeat(64), "c".repeat(64))
        assertEquals(elsewhere, ContactManager.saveBase(me, elsewhere, false, false, known = launch))
        // A lagging relay never wins over a copy this device already holds.
        assertEquals(elsewhere, ContactManager.saveBase(me, launch, false, false, known = elsewhere))
        // Another account's copy is never the base.
        val other = copy(300, "d".repeat(64), owner = "e".repeat(64))
        assertEquals(launch, ContactManager.saveBase(me, launch, false, false, known = other))
    }

    @Test fun anEditAppliesToWhateverTheNewestCopyHolds() {
        val b = "b".repeat(64); val c = "c".repeat(64); val d = "d".repeat(64)
        assertEquals(listOf(b, c, d), ContactManager.FollowEdit(add = listOf(d)).applyTo(listOf(b, c)))
        assertEquals(listOf(c), ContactManager.FollowEdit(remove = listOf(b)).applyTo(listOf(b, c)))
        assertEquals(listOf(b, c), ContactManager.FollowEdit(add = listOf(c)).applyTo(listOf(b, c)))
        assertEquals(listOf(d), ContactManager.FollowEdit(replaceWith = listOf(d)).applyTo(listOf(b, c)))
    }
}
