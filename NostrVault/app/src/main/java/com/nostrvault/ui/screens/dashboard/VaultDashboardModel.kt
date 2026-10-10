package com.nostrvault.ui.screens.dashboard

import java.text.SimpleDateFormat
import java.util.Locale

/**
 * The Vault Dashboard's words and numbers, kept out of Compose so they can be
 * tested. Port of the logic in iOS `VaultDashboardView` (Dashboard v2).
 */
internal object VaultDashboardModel {

    /** Is it running? The status card's one state. */
    enum class RunState { RUNNING, IMPORTING, STARTING, PAUSED, NEEDS_FIX }

    fun runState(isBooting: Boolean, isRunning: Boolean, isImporting: Boolean, isLocked: Boolean, isPortConflict: Boolean): RunState = when {
        isLocked || isPortConflict -> RunState.NEEDS_FIX
        isBooting -> RunState.STARTING
        isImporting -> RunState.IMPORTING
        !isRunning -> RunState.PAUSED
        else -> RunState.RUNNING
    }

    /** The halo pulses while the vault is up or coming up. */
    fun pulses(state: RunState): Boolean =
        state == RunState.RUNNING || state == RunState.IMPORTING || state == RunState.STARTING

    fun statusTitle(state: RunState): String = when (state) {
        RunState.RUNNING, RunState.IMPORTING -> "Your vault is running"
        RunState.STARTING -> "Your vault is starting…"
        RunState.PAUSED -> "Your vault is paused"
        RunState.NEEDS_FIX -> "Your vault needs a restart"
    }

    /** Plain words for what is wrong and what the one button does; null when nothing is. */
    fun problemText(state: RunState, isPortConflict: Boolean, port: Int): String? = when (state) {
        RunState.PAUSED -> "It isn't saving new notes or messages. Start it to catch up."
        RunState.NEEDS_FIX ->
            if (isPortConflict) "Another app is using port $port. Restarting clears it."
            else "The last session didn't shut down cleanly. Restarting clears the lock."
        else -> null
    }

    fun fixButtonTitle(state: RunState): String = if (state == RunState.PAUSED) "Start vault" else "Restart vault"

    /** "Up 2d 3h", "Up 4h 12m", "Up 7m"; null without a start time. */
    fun uptime(startMs: Long?, nowMs: Long): String? {
        if (startMs == null || startMs <= 0) return null
        val seconds = maxOf(0L, (nowMs - startMs) / 1000)
        val days = seconds / 86_400
        val hours = (seconds % 86_400) / 3_600
        val minutes = (seconds % 3_600) / 60
        val up = when {
            days > 0 -> "${days}d ${hours}h"
            hours > 0 -> "${hours}h ${minutes}m"
            else -> "${minutes}m"
        }
        return "Up $up"
    }

    /**
     * A past time in words, like Foundation's `.relative(presentation: .named)`:
     * "now", "5 minutes ago", "yesterday", "last week", "3 months ago".
     */
    fun relative(thenMs: Long, nowMs: Long): String {
        val seconds = maxOf(0L, (nowMs - thenMs) / 1000)
        fun ago(n: Long, unit: String, last: String? = null): String =
            if (n == 1L && last != null) last else if (n == 1L) "1 $unit ago" else "$n ${unit}s ago"
        return when {
            seconds < 60 -> "now"
            seconds < 3_600 -> ago(seconds / 60, "minute")
            seconds < 86_400 -> ago(seconds / 3_600, "hour")
            seconds < 7 * 86_400 -> ago(seconds / 86_400, "day", "yesterday")
            seconds < 30 * 86_400 -> ago(seconds / (7 * 86_400), "week", "last week")
            seconds < 365 * 86_400 -> ago(seconds / (30 * 86_400), "month", "last month")
            else -> ago(seconds / (365 * 86_400), "year", "last year")
        }
    }

    /** "Is it safe?": how many of the four are done. */
    fun safetyDoneCount(keyOk: Boolean, followListSaved: Boolean, macConfigured: Boolean, backupMade: Boolean): Int =
        listOf(keyOk, followListSaved, macConfigured, backupMade).count { it }

    fun keyTitle(usesSigner: Boolean, hasLocalKey: Boolean): String = when {
        usesSigner -> "Your key is in a signer app"
        hasLocalKey -> "Your key is on this device"
        else -> "No key on this device"
    }

    fun keyDetail(usesSigner: Boolean, hasLocalKey: Boolean): String = when {
        usesSigner -> "Nostr Vault asks it to sign."
        hasLocalKey -> "Encrypted with your password."
        else -> "You can read, but not post or sign."
    }

    fun followListDetail(lastSavedMs: Long?, nowMs: Long): String =
        lastSavedMs?.let { "Last saved ${relative(it, nowMs)}." }
            ?: "Not saved yet. If a client wipes it, you can't get it back."

    fun macSyncDetail(macConfigured: Boolean, finishedAtSeconds: Long?, nowMs: Long): String = when {
        !macConfigured -> "Not set up. Your Mac can keep a copy that's always on."
        finishedAtSeconds == null || finishedAtSeconds <= 0 -> "Set up. Not synced yet."
        else -> "Last synced ${relative(finishedAtSeconds * 1000, nowMs)}."
    }

    fun backupFileDetail(lastMs: Long?, nowMs: Long): String =
        lastMs?.let { "Last made ${relative(it, nowMs)}." } ?: "Never made. Keep one somewhere off this phone."

    fun lastMade(lastMs: Long?, nowMs: Long): String =
        lastMs?.let { "Last made ${relative(it, nowMs)}." } ?: "Never made."

    fun hops(depth: Int): String = if (depth == 1) "1 hop" else "$depth hops"

    fun trustTitle(count: Int): String =
        if (count <= 0) "Trust list not built yet" else "${"%,d".format(Locale.US, count)} people can reach your inbox"

    fun trustDetail(depth: Int): String = "People within ${hops(depth)} of you. Everyone else is kept out."

    fun blockedDetail(count: Int): String = when (count) {
        0 -> "Nobody blocked."
        1 -> "1 person blocked."
        else -> "$count people blocked."
    }

    /** Messages are NIP-04 DMs plus gift wraps; null while counts haven't loaded. */
    fun messagesCount(kindCounts: Map<Int, Int>): Int? =
        if (kindCounts.isEmpty()) null else (kindCounts[4] ?: 0) + (kindCounts[1059] ?: 0)

    fun kindCount(kindCounts: Map<Int, Int>, kind: Int): Int? =
        if (kindCounts.isEmpty()) null else kindCounts[kind] ?: 0

    /** Notes / Media / Cache, in bytes, for the storage bar. */
    data class StorageSplit(val notes: Long, val media: Long, val cache: Long) {
        val total: Long get() = notes + media + cache
    }

    /**
     * The relay data folder holds the databases and the Blossom folder, so
     * notes are what is left after media. The media cache and thumbnails live
     * outside it.
     */
    fun storageSplit(relayDataBytes: Long, blossomBytes: Long, cacheBytes: Long, thumbnailBytes: Long): StorageSplit {
        val media = maxOf(0L, blossomBytes)
        return StorageSplit(
            notes = maxOf(0L, relayDataBytes - media),
            media = media,
            cache = maxOf(0L, cacheBytes) + maxOf(0L, thumbnailBytes),
        )
    }

    /** "None" rather than "0 B". Same units as the rest of the app (StatsService.formatSize). */
    fun size(bytes: Long): String = when {
        bytes <= 0 -> "None"
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "%.1f KB".format(Locale.US, bytes / 1024.0)
        bytes < 1024L * 1024 * 1024 -> "%.1f MB".format(Locale.US, bytes / (1024.0 * 1024))
        else -> "%.2f GB".format(Locale.US, bytes / (1024.0 * 1024 * 1024))
    }

    /** The import start date ("2023-01-01") as "Jan 2023"; the raw text if it doesn't parse. */
    fun importStartText(date: String): String = runCatching {
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { isLenient = false }
        val parsed = parser.parse(date) ?: return date
        SimpleDateFormat("MMM yyyy", Locale.US).format(parsed)
    }.getOrDefault(date)

    fun importNotesDetail(importStartDate: String, lastImportMs: Long?, nowMs: Long): String =
        "Since ${importStartText(importStartDate)}. " +
            (lastImportMs?.let { "Last ran ${relative(it, nowMs)}." } ?: "Never ran.")

    fun importMediaDetail(lastImportMs: Long?, nowMs: Long): String =
        lastImportMs?.let { "Last ran ${relative(it, nowMs)}." } ?: "Copies the media in your notes here."
}
