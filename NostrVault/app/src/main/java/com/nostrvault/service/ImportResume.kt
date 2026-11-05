package com.nostrvault.service

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * An import the app was running, written down when it starts and cleared when it ends. If it's still there on the
 * next start, the process was killed mid-import (START_NOT_STICKY used to drop it for good: Tron's import risks #3,
 * 2026-11-05), so it runs again. Go keeps no cursor; a re-run is idempotent and starts over.
 */
@Serializable
data class CutImport(
    val listHistory: Boolean = false,
    val alsoFrom: List<String> = emptyList(),
    val otherVault: String? = null,
    val startedAt: Long = 0,
    /** Runs so far of this import (the first included); a run that keeps getting killed stops being resumed. */
    val runs: Int = 1,
)

object ImportResume {
    /** Resumed at most this many times in all. */
    const val MAX_RUNS = 3
    /** An import cut longer ago than this is not resumed (the person has long moved on). */
    const val MAX_AGE_S = 24 * 60 * 60L

    private const val PREFS = "import_run"
    private const val KEY = "cut"
    private val json = Json { ignoreUnknownKeys = true }

    /** Whether a found record should run again now. Pure for the tests. */
    fun shouldResume(cut: CutImport?, nowS: Long, busy: Boolean): Boolean =
        cut != null && !busy && cut.runs < MAX_RUNS && nowS - cut.startedAt in 0..MAX_AGE_S

    /** The record for the next run of [cut], or a new one. */
    fun next(previous: CutImport?, listHistory: Boolean, alsoFrom: List<String>, otherVault: String?, nowS: Long): CutImport =
        CutImport(listHistory, alsoFrom, otherVault, previous?.startedAt ?: nowS, (previous?.runs ?: 0) + 1)

    internal fun read(context: Context): CutImport? = runCatching {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.let { json.decodeFromString<CutImport>(it) }
    }.getOrNull()

    internal fun write(context: Context, cut: CutImport) {
        // commit, not apply: the point is surviving a kill right after.
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json.encodeToString(CutImport.serializer(), cut)).commit()
    }

    internal fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).commit()
    }
}
