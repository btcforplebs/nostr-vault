package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplaceableLedgerTest {
    private val key = "10063:abc"

    // The bug: storage is not ready when NostrService is built, so a seed at
    // construction read nothing and an older signed list replayed after launch.
    @Test
    fun seedsFromDiskOnceStorageIsReady() {
        var disk: Map<String, Long>? = null // storage not ready yet
        val ledger = ReplaceableLedger { disk }
        disk = mapOf(key to 200L)

        assertFalse("older list after launch", ledger.mayReplace(key, 100L, "aa"))
        assertTrue(ledger.mayReplace(key, 300L, "aa"))
    }

    @Test
    fun withoutDiskSeedAnOlderListWouldWin() { // control for the test above
        val ledger = ReplaceableLedger { emptyMap() }
        assertTrue(ledger.mayReplace(key, 100L, "aa"))
    }

    @Test
    fun doesNotSaveBeforeTheSeedRan() {
        val ledger = ReplaceableLedger { null }
        ledger.record(key, 100L, "aa")
        assertNull("saving now would overwrite the disk stamps", ledger.snapshot { true })
    }

    @Test
    fun snapshotKeepsSeededAndNewStamps() {
        val ledger = ReplaceableLedger { mapOf(key to 200L, "10002:abc" to 50L) }
        ledger.record("10002:abc", 60L, "bb")
        assertEquals(mapOf(key to 200L, "10002:abc" to 60L), ledger.snapshot { true })
    }

    @Test
    fun sameSecondTieGoesToLowestId() {
        val ledger = ReplaceableLedger { emptyMap() }
        assertTrue(ledger.record(key, 100L, "bb"))
        assertFalse(ledger.record(key, 100L, "cc"))
        assertTrue(ledger.record(key, 100L, "aa"))
        assertTrue("same event again", ledger.record(key, 100L, "aa"))
    }

    @Test
    fun diskProfileCountsAsSeen() {
        val ledger = ReplaceableLedger { emptyMap() }
        assertFalse(ledger.mayReplace("0:abc", 100L, "aa", fallbackSeen = 200L))
        assertTrue(ledger.mayReplace("0:abc", 300L, "aa", fallbackSeen = 200L))
    }
}
