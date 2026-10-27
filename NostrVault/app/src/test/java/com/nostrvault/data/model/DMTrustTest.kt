package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Who reaches the DM inbox: the Web of Trust or a conversation you wrote in.
 * A stranger who merely follows you waits under Requests.
 */
class DMTrustTest {
    private val ownerHex = "0".repeat(64)
    private val friendHex = "f".repeat(64)
    private val strangerHex = "5".repeat(64)
    /** Follows the owner, but the owner does not follow them and the web does not hold them. */
    private val followerHex = "c".repeat(64)

    private val trusted = setOf(ownerHex, friendHex)
    private val own = setOf(ownerHex)

    private data class Convo(val id: String, val wrote: Boolean = false)

    private fun split(convos: List<Convo>, trust: Set<String> = trusted) =
        DMTrust.split(convos, trust, own, { it.id }, { it.wrote })

    @Test
    fun trustedCounterpartyIsInbox() {
        assertTrue(DMTrust.isInbox(friendHex, youWrote = false, trusted = trusted, own = own))
    }

    @Test
    fun strangerIsRequest() {
        assertFalse(DMTrust.isInbox(strangerHex, youWrote = false, trusted = trusted, own = own))
    }

    @Test
    fun strangerWhoOnlyFollowsOwnerIsRequest() {
        // Their follow is not trust: they are in neither the follows nor the web.
        val result = split(listOf(Convo(followerHex), Convo(friendHex)))
        assertEquals(listOf(friendHex), result.inbox.map { it.id })
        assertEquals(listOf(followerHex), result.requests.map { it.id })
    }

    @Test
    fun ownerWroteIsInbox() {
        assertTrue(DMTrust.isInbox(strangerHex, youWrote = true, trusted = trusted, own = own))
    }

    @Test
    fun ownerThemselfIsInbox() {
        assertTrue(DMTrust.isInbox(ownerHex, youWrote = false, trusted = emptySet(), own = own))
    }

    @Test
    fun emptyTrustLetsOnlyWroteInThrough() {
        val convos = listOf(Convo(friendHex), Convo(strangerHex, wrote = true), Convo(followerHex))
        val result = split(convos, trust = emptySet())
        assertEquals(listOf(strangerHex), result.inbox.map { it.id })
        assertEquals(listOf(friendHex, followerHex), result.requests.map { it.id })
    }

    @Test
    fun hexIsComparedCaseInsensitively() {
        val mixed = "AbCd".repeat(16)
        assertTrue(DMTrust.isInbox(mixed, youWrote = false, trusted = setOf(mixed.lowercase()), own = own))
        assertTrue(DMTrust.isInbox(mixed.lowercase(), youWrote = false, trusted = emptySet(), own = setOf(mixed)))
    }

    @Test
    fun splitKeepsOrder() {
        val convos = listOf(Convo(strangerHex), Convo(friendHex), Convo(followerHex), Convo(ownerHex))
        val result = split(convos)
        assertEquals(listOf(friendHex, ownerHex), result.inbox.map { it.id })
        assertEquals(listOf(strangerHex, followerHex), result.requests.map { it.id })
    }
}
