package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Relay tab's Outside filter and a notification tap's routing share this rule (iOS #271). */
class OutsideNetworkTest {
    private val owner = "owner"
    private val friend = "friend"
    private val listed = "listed"
    private val stranger = "stranger"

    private fun outside(author: String, trusted: Set<String>) =
        VaultContentFilter.isOutside(author, owner, whitelist = setOf(owner, listed), trusted = trusted)

    @Test
    fun strangerOutsideTheGraphIsOutside() {
        assertTrue(outside(stranger, trusted = setOf(owner, friend)))
    }

    @Test
    fun trustedOwnerAndWhitelistedAreNot() {
        val trusted = setOf(owner, friend)
        assertFalse(outside(friend, trusted))
        assertFalse(outside(owner, trusted))
        assertFalse(outside(listed, trusted))
    }

    /** Before the graph loads it fails closed like Global (TrustGate, Logen 2026-11-04): strangers are outside, you and the whitelist are not. */
    @Test
    fun emptyGraphFailsClosed() {
        assertTrue(outside(stranger, trusted = emptySet()))
        assertTrue(outside(friend, trusted = emptySet()))
        assertFalse(outside(owner, trusted = emptySet()))
        assertFalse(outside(listed, trusted = emptySet()))
    }
}
