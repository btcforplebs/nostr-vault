package com.nostrvault.ui.screens.dashboard

import com.nostrvault.service.ImportResult
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Gap H (twin of web KeepFullSection and Apple #2444): the Import notes row keeps how the last import ended,
 * complete or not, until the next run. Before, Android showed it 3 s and only for a complete import.
 */
class ImportNotesRowDetailTest {

    private val idle = "Since Jan 2024. Last ran 2 days ago."
    private fun detail(isImporting: Boolean, live: String = "", outcome: ImportResult? = null) =
        VaultDashboardModel.importNotesRowDetail(isImporting, live, outcome?.summary, idle)

    @Test
    fun `while it runs the row shows the live status`() {
        assertEquals("Importing notes from seed relays...", detail(true, "Importing notes from seed relays..."))
        assertEquals("Importing…", detail(true, ""))
        // A result from the run before never covers the live one.
        assertEquals("Stopping relay...", detail(true, "Stopping relay...", ImportResult.CANCELLED))
    }

    @Test
    fun `every kind of ending stays as the detail`() {
        val complete = ImportResult(ImportResult.Status.COMPLETE, emptyList(), 1200, 40, 5, 5, "none")
        val partial = ImportResult(ImportResult.Status.PARTIAL, listOf("relay_timeout"), 1200, 40, 3, 5, "none")
        val noRelay = ImportResult(ImportResult.Status.FAILED, listOf("no_seed_relay"), 0, 0, 0, 5, "none")
        assertEquals(ImportResult.COMPLETE_LINE, detail(false, outcome = complete))
        assertEquals("Imported 1,200 notes, but some may be missing. Run the import again to fill the gaps.", detail(false, outcome = partial))
        assertEquals("Couldn't reach any relay. Check your connection, then try again.", detail(false, outcome = noRelay))
        assertEquals(ImportResult.CANCELLED_LINE, detail(false, outcome = ImportResult.CANCELLED))
        assertEquals(ImportResult.APP_FAILED.summary, detail(false, outcome = ImportResult.APP_FAILED))
    }

    @Test
    fun `with no ending this session the row shows its last ran line`() {
        assertEquals(idle, detail(false))
        // The live status a finished run leaves behind is not a result on its own.
        assertEquals(idle, detail(false, "Import Complete!"))
    }
}
