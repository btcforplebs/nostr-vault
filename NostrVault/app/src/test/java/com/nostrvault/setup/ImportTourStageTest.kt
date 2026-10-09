package com.nostrvault.setup

import com.nostrvault.relay.RelayLogParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The messages here are the exact strings RelayLogParser sets. Mirrors iOS
 *  ImportTourStageTests. */
class ImportTourStageTest {
    @Test fun stagesFollowTheImport() {
        assertEquals(1, ImportTourStage.from("Starting import for npub1abc...", false).step)
        assertEquals(1, ImportTourStage.from("Connected to relays...", false).step)
        assertEquals(1, ImportTourStage.from("Building Web of Trust...", false).step)
        assertEquals(ImportTourStage("Saving your notes from Mar 2024…", 2), ImportTourStage.from("Found notes from 2024-03-05...", false))
        assertEquals(ImportTourStage("Saving your notes…", 2), ImportTourStage.from("Found notes...", false))
        assertEquals(3, ImportTourStage.from("Importing tagged notes...", false).step)
        assertEquals(4, ImportTourStage.from("Import Complete!", true).step)
    }

    @Test fun monthParsing() {
        assertEquals("Jan 2023", ImportTourStage.month("Found notes from 2023-01-31T12:00:00Z..."))
        assertEquals("Dec 2021", ImportTourStage.month("Found notes from 2021-12-01 ..."))
        assertNull(ImportTourStage.month("Found notes from yesterday..."))
        assertNull(ImportTourStage.month("Found notes..."))
    }

    /** Empty windows move the headline too (import.go "No notes found"). */
    @Test fun emptyWindowsKeepTheHeadlineMoving() {
        val batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges("2026/10/08 00:28:01 ℹ️ No notes found for 2021-05-21 to 2021-05-31", batch)
        assertEquals("2021-05-31", batch.progressDateStr)
        assertEquals("Looking through notes from 2021-05-21...", batch.importStatusMessage)
        assertEquals(ImportTourStage("Looking through May 2021…", 2), ImportTourStage.from(batch.importStatusMessage.orEmpty(), false))
    }

    /** The pill over the app: "Importing · notes from Mar 2024". */
    @Test fun pillText() {
        assertEquals("notes from Mar 2024", ImportTourStage.shortText(ImportTourStage.from("Found notes from 2024-03-05...", false)))
        assertEquals("may 2021", ImportTourStage.shortText(ImportTourStage("Looking through May 2021…", 2)))
        assertEquals("connecting to your relays", ImportTourStage.shortText(ImportTourStage.from("", false)))
    }
}
