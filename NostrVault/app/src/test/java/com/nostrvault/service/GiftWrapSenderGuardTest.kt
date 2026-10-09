package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The seal is the only layer that proves who sent a NIP-17 DM; the rumor's
 * pubkey is a claim inside it. A stranger who seals with their own key must
 * not be able to name someone else (or the recipient) as the author.
 */
class GiftWrapSenderGuardTest {

    private val mallory = "a".repeat(64)
    private val alice = "b".repeat(64)

    private fun seal(pubkey: String, kind: Int = 13) =
        Json.parseToJsonElement("""{"pubkey":"$pubkey","kind":$kind,"content":"x"}""").jsonObject

    private fun rumor(pubkey: String?, kind: Int = 14) =
        if (pubkey == null) """{"kind":$kind,"content":"hi"}"""
        else """{"pubkey":"$pubkey","kind":$kind,"content":"hi"}"""

    @Test
    fun `rumor authored by the sealer is accepted`() {
        assertTrue(NIP17Service.isAuthoredBySealer(seal(alice), rumor(alice)))
    }

    @Test
    fun `rumor claiming another author is rejected`() {
        assertFalse(NIP17Service.isAuthoredBySealer(seal(mallory), rumor(alice)))
    }

    @Test
    fun `rumor with no author is rejected`() {
        assertFalse(NIP17Service.isAuthoredBySealer(seal(mallory), rumor(null)))
    }

    @Test
    fun `wrong seal or rumor kind is rejected`() {
        assertFalse(NIP17Service.isAuthoredBySealer(seal(alice, kind = 1), rumor(alice)))
        assertFalse(NIP17Service.isAuthoredBySealer(seal(alice), rumor(alice, kind = 1)))
    }

    @Test
    fun `unparseable rumor is rejected`() {
        assertFalse(NIP17Service.isAuthoredBySealer(seal(alice), "not json"))
    }
}
