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

    // Tron round 5: an older kind 0 accepted before the disk profile loaded
    // must not shadow the newer disk copy, in the merge or in the ledger.
    @Test
    fun olderProfileFromTheLoadWindowLosesToDisk() {
        val disk = mapOf("abc" to 200L)
        val memory = mapOf("abc" to 100L, "new" to 50L)
        assertEquals(mapOf("abc" to 200L, "new" to 50L), mergeNewer(disk, memory) { it })
        assertEquals(mapOf("abc" to 300L), mergeNewer(disk, mapOf("abc" to 300L)) { it })

        val ledger = ReplaceableLedger { emptyMap() }
        assertTrue(ledger.record("0:abc", 100L, "aa")) // before the disk load
        assertFalse("between old and disk copy", ledger.mayReplace("0:abc", 150L, "aa", fallbackSeen = 200L))
        assertTrue(ledger.mayReplace("0:abc", 250L, "aa", fallbackSeen = 200L))
    }

    // Tron round 6: profiles cached before created_at was kept have none; on
    // the first launch after the upgrade they must not lose to the load window.
    @Test
    fun unknownCreatedAtKeepsTheDiskCopy() {
        val disk = mapOf<String, Long?>("abc" to null, "def" to 200L)
        val memory = mapOf<String, Long?>("abc" to 100L, "def" to null, "new" to null)
        assertEquals(mapOf("abc" to null, "def" to 200L, "new" to null), mergeNewer(disk, memory) { it })
    }
}
