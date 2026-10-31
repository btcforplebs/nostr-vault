package com.nostrvault.service

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The photo screen's "which Blossom servers hold this file" answers, kept for
 * a day so reopening a photo, or relaunching the app, does not ask every
 * server again. Port of iOS `BlossomPresenceDisk`.
 *
 * Only full answers are kept. "Could not ask" never is: a server that was
 * down should be asked again next time, not shown as "?" for a day.
 */
@Serializable
data class BlossomPresenceDisk(val entries: Map<String, Entry> = emptyMap()) {
    @Serializable
    data class Entry(
        /** Unix millis of the check. */
        val checkedAt: Long,
        /** Server URL to whether it holds the file. */
        val servers: Map<String, Boolean>,
    )

    companion object {
        const val MAX_AGE_MS = 24L * 60 * 60 * 1000
        /** Newest files kept; older ones are asked again when opened. */
        const val MAX_ENTRIES = 5000
    }

    /** Whether the answer for [hash] is young enough to show without asking. */
    fun isFresh(hash: String, now: Long): Boolean {
        val entry = entries[hash] ?: return false
        return now - entry.checkedAt < MAX_AGE_MS
    }

    /** One check stored; if any server could not be asked the entry is dropped instead. */
    fun storing(hash: String, answers: Map<String, BlobPresence>, now: Long): BlossomPresenceDisk {
        if (answers.isEmpty() || answers.values.any { it == BlobPresence.UNREACHABLE }) {
            return copy(entries = entries - hash)
        }
        return copy(entries = entries + (hash to Entry(now, answers.mapValues { it.value == BlobPresence.PRESENT })))
    }

    /** Drops answers a day old or older and keeps the newest [MAX_ENTRIES]. */
    fun pruned(now: Long): BlossomPresenceDisk {
        var kept = entries.filterValues { now - it.checkedAt < MAX_AGE_MS }
        if (kept.size > MAX_ENTRIES) {
            kept = kept.entries.sortedByDescending { it.value.checkedAt }.take(MAX_ENTRIES)
                .associate { it.key to it.value }
        }
        return BlossomPresenceDisk(kept)
    }

    /** The answers as the service's presence map. */
    fun presence(): Map<String, Map<String, BlobPresence>> =
        entries.mapValues { (_, entry) ->
            entry.servers.mapValues { if (it.value) BlobPresence.PRESENT else BlobPresence.ABSENT }
        }
}

/**
 * Where [BlossomPresenceDisk] lives: `cache/blossom_presence.json`. A null
 * [file] keeps the answers in memory only (tests).
 */
@Singleton
class BlossomPresenceStore(
    private val file: File?,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Inject constructor(@ApplicationContext context: Context) : this(File(context.cacheDir, FILE_NAME))

    private companion object {
        const val FILE_NAME = "blossom_presence.json"
        const val SAVE_DELAY_MS = 2_000L
        val json = Json { ignoreUnknownKeys = true }
    }

    private val lock = Any()
    private var disk = BlossomPresenceDisk()
    private var saveJob: Job? = null

    /** Reads the saved answers, dropping old ones. Call once, off the main thread. */
    fun load(): BlossomPresenceDisk {
        val saved = runCatching { file?.takeIf { it.exists() }?.readText()?.let { json.decodeFromString<BlossomPresenceDisk>(it) } }
            .onFailure { Log.w("BlossomPresence", "Unreadable $FILE_NAME: ${it.message}") }
            .getOrNull() ?: BlossomPresenceDisk()
        return saved.pruned(clock()).also { synchronized(lock) { disk = it } }
    }

    fun isFresh(hash: String): Boolean = synchronized(lock) { disk.isFresh(hash, clock()) }

    /** Records one check and writes the file a moment later, so a burst of checks is one write. */
    fun record(hash: String, answers: Map<String, BlobPresence>, scope: CoroutineScope) {
        synchronized(lock) {
            disk = disk.storing(hash, answers, clock())
            if (file == null) return
            saveJob?.cancel()
            saveJob = scope.launch {
                delay(SAVE_DELAY_MS)
                save()
            }
        }
    }

    private fun save() {
        val target = file ?: return
        val snapshot = synchronized(lock) { disk.pruned(clock()).also { disk = it } }
        runCatching {
            val tmp = File(target.parentFile, "$FILE_NAME.tmp")
            tmp.writeText(json.encodeToString(BlossomPresenceDisk.serializer(), snapshot))
            if (!tmp.renameTo(target)) error("rename failed")
        }.onFailure { Log.w("BlossomPresence", "Couldn't save $FILE_NAME: ${it.message}") }
    }
}
