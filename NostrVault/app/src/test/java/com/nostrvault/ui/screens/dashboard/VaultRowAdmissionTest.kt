package com.nostrvault.ui.screens.dashboard

import com.nostrvault.data.model.VaultActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultRowAdmissionTest {
    private val now = 1_800_000_000L
    private val publisher = "aa".repeat(32)
    private val forger = "ff".repeat(32)
    private val recipient = "bb".repeat(32)
    private val onlyPublisher: suspend (String, String) -> Boolean = { r, _ -> r == publisher }

    private fun admitted(kind: Int, pubkey: String, at: Long, tags: List<List<String>>) =
        runBlocking { vaultRowAdmitted(kind, pubkey, at, tags, now, onlyPublisher) }

    @Test
    fun forgedZapReceiptIsRefused() {
        assertFalse(admitted(9735, forger, now - 3_600, listOf(listOf("p", recipient))))
        assertTrue(admitted(9735, publisher, now - 3_600, listOf(listOf("p", recipient))))
    }

    @Test
    fun zapReceiptWithNoRecipientIsRefused() {
        assertFalse(admitted(9735, publisher, now - 3_600, emptyList()))
    }

    @Test
    fun futureDatedPostIsRefused() {
        assertFalse(admitted(1, recipient, now + VaultActivity.MAX_FUTURE_SKEW + 1, emptyList()))
        assertTrue(admitted(1, recipient, now - 60, emptyList()))
    }
}
