package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/PostingAccountTests.swift.
 */
class PostingAccountTest {
    private val owner = "npub1owner"
    private val alt = "npub1alt"
    private val ownerHex = "a".repeat(64)
    private val altHex = "b".repeat(64)

    @Test fun emptyActiveResolvesToOwner() {
        assertEquals(owner, PostingAccount.resolve("", owner))
        assertEquals(owner, PostingAccount.resolve("  ", owner))
        assertEquals(owner, PostingAccount.resolve(null, owner))
        assertEquals(alt, PostingAccount.resolve(alt, owner))
    }

    @Test fun sameAccountAndKeyIsAllowed() {
        assertTrue(PostingAccount.signedAsLocked(PostingAccount.Lock(alt, altHex), activeNow = alt, owner = owner, eventPubkey = altHex))
        // Owner stored as null / "" (the switcher's form) still matches an owner lock.
        assertTrue(PostingAccount.signedAsLocked(PostingAccount.Lock(owner, ownerHex), activeNow = null, owner = owner, eventPubkey = ownerHex))
        assertTrue(PostingAccount.signedAsLocked(PostingAccount.Lock(owner, ownerHex), activeNow = "", owner = owner, eventPubkey = ownerHex.uppercase()))
    }

    @Test fun switchDuringUploadIsRefused() {
        val ownerLock = PostingAccount.Lock(owner, ownerHex)
        // Locked as owner; account switched to alt; note signed by alt.
        assertFalse(PostingAccount.signedAsLocked(ownerLock, activeNow = alt, owner = owner, eventPubkey = altHex))
        // Switched away and back during the sign is fine only if the key matches.
        assertFalse(PostingAccount.signedAsLocked(ownerLock, activeNow = null, owner = owner, eventPubkey = altHex))
        // Signed as the locked account, but the active account changed: refused.
        assertFalse(PostingAccount.signedAsLocked(ownerLock, activeNow = alt, owner = owner, eventPubkey = ownerHex))
    }

    @Test fun missingLockedKeyIsRefused() {
        assertFalse(PostingAccount.signedAsLocked(PostingAccount.Lock(owner, ""), activeNow = null, owner = owner, eventPubkey = ""))
    }
}
