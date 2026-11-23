package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A catch-up's end line (the engine prints one since #2480, the same shape as these) in the record. Twin of Apple's
 * MeshCopyV2RecordTests catch-up cases.
 */
class MeshCopyV2RecordTest {
    private val mac = "npub1mac"
    private val box = "npub1box"
    private fun line(s: String) = MeshCopyV2.parseLine(s)!!

    @Test
    fun `a catch-up's done line leaves another device's pending first copy alone`() {
        val pending = MeshCopyV2.Record.Pending(box, "Box", freshStart = false)
        val r = MeshCopyV2.Record(pending = pending, copied = mapOf(mac to 1L), unreachableSince = 5L)
            .finished(line("COPY stage=done part=- bytes=0/0 items=3/3 source=mesh"), mac, 100L)
        assertEquals(pending, r.pending)
        assertEquals(5L, r.unreachableSince)
        assertEquals(mapOf(mac to 100L), r.copied)
    }

    @Test
    fun `a catch-up that fails for good is stamped, one cut short stays due`() {
        val r = MeshCopyV2.Record(copied = mapOf(mac to 1L))
        val refused = r.finished(line("COPY stage=failed part=- bytes=0/0 items=0/0 source=mesh error=not_owner"), mac, 100L)
        assertEquals(mapOf(mac to 100L), refused.copied)
        for (code in MeshCopyV2.CUT_SHORT) {
            val cut = r.finished(line("COPY stage=failed part=- bytes=0/0 items=0/0 source=mesh error=$code"), mac, 100L)
            assertEquals(code, mapOf(mac to 1L), cut.copied)
        }
    }

    @Test
    fun `a catch-up's failed line leaves another device's pending first copy alone`() {
        val pending = MeshCopyV2.Record.Pending(box, "Box", freshStart = false)
        val r = MeshCopyV2.Record(pending = pending, copied = mapOf(mac to 1L))
            .finished(line("COPY stage=failed part=- bytes=0/0 items=0/0 source=mesh error=not_owner"), mac, 100L)
        assertEquals(pending, r.pending)
    }
}
