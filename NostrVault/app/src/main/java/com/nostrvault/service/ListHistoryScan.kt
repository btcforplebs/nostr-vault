package com.nostrvault.service

/**
 * Moving in's look for older versions of the owner's lists (haven-go
 * list_history_scan.go): the switch the app sets and what it reports. The
 * switch is on by default and the user can turn it off (Logen 2026-11-04 14:34Z);
 * what it finds goes to the
 * vault's import store, where Recover a List sees it. Never published.
 * Twin of iOS `ListHistoryScan.swift`.
 */
object ListHistoryScan {
    /** haven-go listHistoryOptInEnv: "1" runs the scan for this import. */
    const val OPT_IN_ENV = "HAVEN_IMPORT_LIST_HISTORY"

    /** haven-go listHistoryAccountEnv: the hex pubkey of the account moving in, the only one asked about (Tron, PR 1641). */
    const val ACCOUNT_ENV = "HAVEN_IMPORT_LIST_HISTORY_ACCOUNT"

    /** The option's title, word for word (Logen 2026-11-04 14:34Z, same on every platform). */
    const val OPT_IN_TITLE = "Look up and back up my lists"

    /** The small line under it; [LAZARUS_WORD] links to [LAZARUS_URL] (opens in the browser). */
    const val OPT_IN_NOTE = "Finds older versions using Lazarus spec"
    const val LAZARUS_WORD = "Lazarus"
    const val LAZARUS_URL = "https://github.com/dmnyc/lazarus"

    /** On unless the person turns it off (Logen 2026-11-04 14:34Z; was off). Off skips every history relay. */
    const val DEFAULT_ON = true

    const val LOOKING = "Looking for older versions of your lists…"

    /** Read by ImportTourStage as "Looking through your history…". */
    const val NOTES_NEXT = "Looking through notes…"

    /** The /lists filter `#v` value that asks for the imported versions only (haven-go wantsImported). */
    const val IMPORTED_FILTER_VALUE = "imported"

    /** haven-go historyScanRunning. */
    private const val RUNNING = "scanning"

    /** What ListHistoryScanStatusC reports: no scan, running, or done with its closing line. */
    sealed interface Status {
        data object None : Status
        data object Running : Status
        data class Done(val line: String) : Status
    }

    fun status(raw: String?): Status = when {
        raw.isNullOrBlank() -> Status.None
        raw == RUNNING -> Status.Running
        else -> Status.Done(raw)
    }

    /** The line shown after the scan; a find points to where the versions are. */
    fun note(line: String): String = if (line.startsWith("Found")) "$line See them in Recover a List." else line

    /**
     * What the wipe alarm judges: only the versions the vault filed itself. An
     * old clobber found on the relays is not a new wipe (Tron, PR 1639).
     */
    fun alarmInput(groups: Map<ListHistory.Key, List<ListVersion>>, imported: Set<String>): Map<ListHistory.Key, List<ListVersion>> =
        if (imported.isEmpty()) groups
        else groups.mapValues { (_, vs) -> vs.filterNot { it.id in imported } }.filterValues { it.isNotEmpty() }
}
