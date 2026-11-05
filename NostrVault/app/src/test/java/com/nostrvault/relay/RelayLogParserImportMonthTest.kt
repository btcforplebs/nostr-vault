package com.nostrvault.relay

import com.nostrvault.setup.ImportTourStage
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The setup screen shows the month the import is really on: an Imported
 * line's END date. Mirrors iOS RelayLogParserRangeTests.
 */
class RelayLogParserImportMonthTest {
    private fun status(line: String): String? {
        val batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(line, batch)
        return batch.importStatusMessage
    }

    /** A whole-history lane logs "from <start> to <today>" (12 mini, 2026-11-05: stuck on "Jan 2023"). */
    @Test fun `a whole-history lane shows the end month`() {
        val s = status("2026/11/05 00:49:54 📦 Imported 11 notes from 2023-01-01 to 2026-11-05 (wss://relay.snort.social, paged)")
        assertEquals("Found notes from 2026-11-05...", s)
        assertEquals("Saving your notes from Nov 2026…", ImportTourStage.from(s!!, false).text)
    }

    @Test fun `a window line shows the month it reached`() {
        assertEquals("Found notes from 2024-03-15...", status("2026/11/05 00:51:00 📦 Imported 7 notes from 2024-03-05 to 2024-03-15 (window by window)"))
    }

    @Test fun `an empty window still moves the month`() {
        assertEquals("Looking through notes from 2023-08-09...", status("2026/11/05 00:51:00 ℹ️ No notes found for 2023-08-09 to 2023-08-19"))
    }

    @Test fun `a line without a date falls back`() {
        assertEquals("Found notes...", status("Imported 4 notes to inbox from relay.damus.io"))
    }
}
