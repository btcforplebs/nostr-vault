package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Start fresh must keep the old credential store until the fresh one is fully in (Logen, 3.0.0 43): it used to delete
 * the old store before the fresh one opened, so a failed open or the app killed in between lost both.
 */
class FreshStoreSwapTest {

    @get:Rule val tmp = TemporaryFolder()

    /** Stands in for the process dying: not an Exception, so nothing in the swap catches it. */
    private class Killed : Error()

    private val old = "<map><string name=\"nsec-hex-ab\">old keys</string></map>"

    private fun store(): File = File(tmp.root, "nostrvault_credentials.xml").apply { writeText(old) }
    private fun swapFor(live: File) = FreshStoreSwap(live, deleteLive = { live.delete() })
    private fun keepAs() = File(tmp.root, "nostrvault_credentials.unreadable-1.xml")

    /** The fresh store's open: writes the empty file, as EncryptedSharedPreferences does. */
    private fun freshOpen(live: File, then: () -> Unit = {}): () -> String = {
        live.writeText("<map />")
        then()
        "fresh"
    }

    @Test fun killedWhileTheFreshStoreIsBeingSetUpKeepsTheOldStore() {
        val live = store()
        runCatching { swapFor(live).run(openFresh = freshOpen(live) { throw Killed() }, keepAs = keepAs()) }
        // Midway: the old store is out of the live slot, a half-made fresh one is in it.
        assertEquals("<map />", live.readText())

        // Next launch: CredentialStore.init runs recover() before it opens anything.
        assertTrue(swapFor(live).recover())
        assertEquals(old, live.readText())
        assertFalse(swapFor(live).pending.exists())
    }

    @Test fun killedAfterTheOldStoreIsDeletedButBeforeTheFreshOneExists() {
        val live = store()
        runCatching { swapFor(live).run<String>(openFresh = { throw Killed() }, keepAs = keepAs()) }
        assertFalse(live.exists())

        assertTrue(swapFor(live).recover())
        assertEquals(old, live.readText())
    }

    @Test fun aFreshStoreThatWillNotOpenPutsTheOldOneBack() {
        val live = store()
        val opened = swapFor(live).run<String>(openFresh = { live.writeText("<map />"); throw IllegalStateException("keystore") }, keepAs = keepAs())
        assertNull(opened)
        assertEquals("the screen's 'Nothing was changed' is true", old, live.readText())
        assertFalse(swapFor(live).pending.exists())
        assertFalse(keepAs().exists())
    }

    @Test fun aFreshStoreThatWillNotTakeAWriteIsNotDone() {
        val live = store()
        assertNull(swapFor(live).run(openFresh = { live.writeText("<map />"); null }, keepAs = keepAs()))
        assertEquals(old, live.readText())
    }

    @Test fun onceTheFreshStoreIsInTheOldOneIsMovedAsideAndNeverComesBack() {
        val live = store()
        assertEquals("fresh", swapFor(live).run(openFresh = freshOpen(live), keepAs = keepAs()))
        assertEquals(old, keepAs().readText())
        assertFalse(swapFor(live).pending.exists())

        // The person signs in again; later launches must not put the old store back over the new keys.
        live.writeText("<map><string name=\"nsec-hex-cd\">new keys</string></map>")
        assertFalse(swapFor(live).recover())
        assertTrue(live.readText().contains("new keys"))
    }

    @Test fun killedWhileCopyingTheOldStoreLeavesItUntouched() {
        val live = store()
        // A copy cut short: the temp file exists, the pending copy never got its name.
        File(tmp.root, "nostrvault_credentials.pending-old.tmp").writeText("<map><str")
        assertFalse(swapFor(live).recover())
        assertEquals(old, live.readText())
        assertFalse(File(tmp.root, "nostrvault_credentials.pending-old.tmp").exists())
    }

    @Test fun noOldStoreOnDiskStillOpensAFreshOne() {
        val live = File(tmp.root, "nostrvault_credentials.xml")
        assertEquals("fresh", swapFor(live).run(openFresh = freshOpen(live), keepAs = keepAs()))
        assertFalse(keepAs().exists())
    }
}
