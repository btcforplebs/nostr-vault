package com.nostrvault.service

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Following Backup's relay scan keeps only the owner's own, validly signed kind 3. */
class OwnSignedContactListTest {

    private val owner = "a".repeat(64)
    private fun event(kind: Int = 3, pubkey: String = owner) = buildJsonObject {
        put("id", "e".repeat(64))
        put("kind", kind)
        put("pubkey", pubkey)
        put("content", "")
    }

    @Test
    fun `the owner's signed list counts`() {
        assertTrue(isOwnSignedContactList(event(), owner) { true })
    }

    @Test
    fun `someone else's list is dropped even with a good signature`() {
        assertFalse(isOwnSignedContactList(event(pubkey = "b".repeat(64)), owner) { true })
    }

    @Test
    fun `a list that fails verification is dropped`() {
        assertFalse(isOwnSignedContactList(event(), owner) { false })
    }

    @Test
    fun `other kinds are dropped`() {
        assertFalse(isOwnSignedContactList(event(kind = 10002), owner) { true })
    }
}
