package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Vault tab's Zaps > Received list hides blocked zappers. */
class VaultZapsReceivedTest {
    private val owner = "a".repeat(64)
    private val blockedZapper = "b".repeat(64)
    private val friend = "c".repeat(64)
    private val myNote = "1".repeat(64)
    private val otherNote = "2".repeat(64)

    private fun receipt(sender: String, note: String?, sats: Long, at: Long) =
        VaultZapsReceived.Receipt(ParsedZapReceipt(sender, note, sats, requestIsSigned = true), at)

    @Test fun `a blocked zapper is hidden and an unblocked one still shows`() {
        val receipts = listOf(
            receipt(blockedZapper, myNote, 500, at = 200),
            receipt(friend, myNote, 21, at = 100),
        )
        val result = VaultZapsReceived.build(receipts, setOf(myNote), owner, isBlocked = { it == blockedZapper })
        assertEquals(mapOf(myNote to listOf(friend to 21L)), result.zappers)
        // The blocked zap's newer time must not float the note up either.
        assertEquals(100L, result.lastZapAt[myNote])
    }

    @Test fun `a note only a blocked user zapped drops out of the list`() {
        val receipts = listOf(receipt(blockedZapper, myNote, 500, at = 200))
        val result = VaultZapsReceived.build(receipts, setOf(myNote), owner, isBlocked = { it == blockedZapper })
        assertNull(result.zappers[myNote])
        assertNull(result.lastZapAt[myNote])
    }

    @Test fun `unblocking brings the zap back`() {
        val receipts = listOf(receipt(blockedZapper, myNote, 500, at = 200))
        val result = VaultZapsReceived.build(receipts, setOf(myNote), owner, isBlocked = { false })
        assertEquals(mapOf(myNote to listOf(blockedZapper to 500L)), result.zappers)
        assertEquals(200L, result.lastZapAt[myNote])
    }

    @Test fun `own zaps and zaps on other notes are left out`() {
        val receipts = listOf(
            receipt(owner, myNote, 10, at = 1),
            receipt(friend, otherNote, 10, at = 2),
            receipt(friend, null, 10, at = 3),
        )
        val result = VaultZapsReceived.build(receipts, setOf(myNote), owner)
        assertEquals(emptyMap<String, List<Pair<String, Long>>>(), result.zappers)
    }

    @Test fun `a post's zap row keeps your own zap but still hides a blocked zapper`() {
        val receipts = listOf(
            receipt(owner, myNote, 10, at = 1),
            receipt(friend, myNote, 21, at = 2),
            receipt(blockedZapper, myNote, 500, at = 3),
        )
        val result = VaultZapsReceived.build(receipts, setOf(myNote), owner,
            isBlocked = { it == blockedZapper }, excludeOwner = false)
        assertEquals(mapOf(myNote to listOf(owner to 10L, friend to 21L)), result.zappers)
    }
}
