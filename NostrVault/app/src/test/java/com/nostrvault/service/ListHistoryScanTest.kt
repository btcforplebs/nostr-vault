package com.nostrvault.service

import com.nostrvault.setup.ImportTourStage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Moving in's list history scan (haven-go list_history_scan.go): what Android reads and how Recover splits it. */
class ListHistoryScanTest {
    private fun follows(n: Int, at: Long, id: String, client: String? = null) = ListVersion(
        id, "me", 3, at,
        (0 until n).map { listOf("p", "%064x".format(it + 1)) } + listOfNotNull(client?.let { listOf("client", it) }),
        "",
    )

    /**
     * Tron's probe (PR 1639): 200 follows cut to 50 on purpose with Amethyst in 2025, then 10 more edits. The vault
     * filed only the newest; the import found the rest. Recover shows them all; the banner raises nothing.
     */
    @Test
    fun importedClobberRaisesNoAlarm() {
        val cut = 1_750_000_000L
        val imported = mutableListOf(follows(200, cut - 86_400, "full"), follows(50, cut, "cut", "Amethyst"))
        for (i in 1..10) imported += follows(50 + i, cut + i * 86_400L, "edit$i")
        val own = listOf(follows(61, 1_790_000_000L, "now"))
        val groups = ListHistory.group(own + imported, "me")
        val ids = imported.map { it.id }.toSet()

        // Control: judged together, the old cut is an alarm.
        val merged = ListWipeAlarmRule.alarms(groups, emptySet(), emptySet())
        assertEquals(1, merged.size)
        assertEquals(200, merged[0].second.from)
        assertEquals(50, merged[0].second.to)
        assertEquals("Amethyst", merged[0].second.client)

        val input = ListHistoryScan.alarmInput(groups, ids)
        assertEquals(listOf("now"), input.values.single().map { it.id })
        assertTrue(ListWipeAlarmRule.alarms(input, emptySet(), emptySet()).isEmpty())
        assertEquals(13, ListHistoryScan.alarmInput(groups, emptySet()).values.single().size)
    }

    @Test
    fun statusFromGo() {
        assertEquals(ListHistoryScan.Status.None, ListHistoryScan.status(null))
        assertEquals(ListHistoryScan.Status.None, ListHistoryScan.status(""))
        assertEquals(ListHistoryScan.Status.Running, ListHistoryScan.status("scanning"))
        assertEquals(ListHistoryScan.Status.Done("No older versions of your lists found."), ListHistoryScan.status("No older versions of your lists found."))
    }

    @Test
    fun noteSaysWhereToLook() {
        assertEquals("Found 12 older versions of your lists. See them in Recover a List.", ListHistoryScan.note("Found 12 older versions of your lists."))
        assertEquals("No older versions of your lists found.", ListHistoryScan.note("No older versions of your lists found."))
    }

    @Test
    fun tourHeadline() {
        assertEquals(ImportTourStage("Looking for older versions of your lists…", 2), ImportTourStage.from(ListHistoryScan.LOOKING, false))
        assertEquals(ImportTourStage("Looking through your history…", 2), ImportTourStage.from(ListHistoryScan.NOTES_NEXT, false))
    }

    @Test
    fun labelIsLogensWordingAndMatchesGo() {
        assertEquals("Look up and back up my lists", ListHistoryScan.OPT_IN_TITLE)
        assertEquals("Finds older versions on Lazarus history relays", ListHistoryScan.OPT_IN_NOTE)
        assertEquals("https://github.com/dmnyc/lazarus", ListHistoryScan.LAZARUS_URL)
        assertTrue("the note links its own word", ListHistoryScan.OPT_IN_NOTE.contains(ListHistoryScan.LAZARUS_WORD))
        assertTrue("on by default (Logen 2026-11-04 14:34Z)", ListHistoryScan.DEFAULT_ON)
        assertEquals("HAVEN_IMPORT_LIST_HISTORY", ListHistoryScan.OPT_IN_ENV)
        assertEquals("HAVEN_IMPORT_LIST_HISTORY_ACCOUNT", ListHistoryScan.ACCOUNT_ENV)
        assertEquals("imported", ListHistoryScan.IMPORTED_FILTER_VALUE)
    }
}
