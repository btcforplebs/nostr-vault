package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test fun selfHealNeverRepublishesAListUnderHalfTheRelayCopy() {
        // A cached 5 over 500 on relays is a stale or partial list, not a fresh edit.
        assertFalse(ContactManager.mayRepublish(localSize = 5, relaySize = 500))
        assertFalse(ContactManager.mayRepublish(localSize = 0, relaySize = 3))
        // A fresh follow or unfollow the relays haven't caught up on.
        assertTrue(ContactManager.mayRepublish(localSize = 499, relaySize = 500))
        assertTrue(ContactManager.mayRepublish(localSize = 501, relaySize = 500))
        // Small lists: one unfollow may halve them.
        assertTrue(ContactManager.mayRepublish(localSize = 1, relaySize = 2))
    }
}
