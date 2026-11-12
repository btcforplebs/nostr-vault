package com.nostrvault.service

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * What Auto-Mirror keeps between launches, in [dir] (files, not cache: a
 * cleared cache must not let runs start again):
 * - `auto_mirror_start`: when the last run started (rule 3), tiny, read on any thread.
 * - `auto_mirror_links.json`: the SHA-256 each fetched link served (rule 1),
 *   read on first use, which is inside a run, off the main thread.
 * A null [dir] keeps it in memory (tests).
 */
@Singleton
class AutoMirrorState(private val dir: File?) {
    @Inject constructor(@ApplicationContext context: Context) : this(context.filesDir)

    companion object {
        private const val START_FILE = "auto_mirror_start"
        private const val LINKS_FILE = "auto_mirror_links.json"
        /** Links kept; the oldest go first. */
        const val MAX_LINKS = 20_000
        private val json = Json { ignoreUnknownKeys = true }
        private const val TAG = "AutoMirrorState"
    }

    private val lock = Any()
    @Volatile private var start: Long? = null
    private var startRead = false
    private var links: LinkedHashMap<String, String>? = null
    private var dirty = false

    val lastStart: Long?
        get() = synchronized(lock) {
            if (!startRead) {
                startRead = true
                start = runCatching { dir?.let { File(it, START_FILE) }?.takeIf { it.exists() }?.readText()?.trim()?.toLong() }
                    .getOrNull()?.takeIf { it > 0 }
            }
            start
        }

    /** A run started at [at]: written at once, so a relaunch mid-run still counts it. */
    fun recordStart(at: Long) {
        synchronized(lock) { start = at; startRead = true }
        val d = dir ?: return
        runCatching { write(File(d, START_FILE), at.toString()) }
            .onFailure { Log.w(TAG, "Couldn't save $START_FILE: ${it.message}") }
    }

    fun hashFor(url: String): String? = synchronized(lock) { loadedLinks()[url] }

    /** [url] served [sha256]. Kept in memory until [saveIfChanged]. */
    fun remember(url: String, sha256: String) {
        val hash = sha256.lowercase()
        if (!AutoMirrorRules.isHash(hash)) return
        synchronized(lock) {
            val map = loadedLinks()
            if (map[url] == hash) return
            map.remove(url)
            map[url] = hash
            while (map.size > MAX_LINKS) map.remove(map.keys.first())
            dirty = true
        }
    }

    /** Writes the links if any changed. */
    fun saveIfChanged() {
        val d = dir ?: return
        val snapshot = synchronized(lock) {
            if (!dirty) return
            dirty = false
            LinkedHashMap(loadedLinks())
        }
        runCatching { write(File(d, LINKS_FILE), json.encodeToString(LinkMap.serializer(), LinkMap(snapshot))) }
            .onFailure { Log.w(TAG, "Couldn't save $LINKS_FILE: ${it.message}") }
    }

    private fun loadedLinks(): LinkedHashMap<String, String> {
        links?.let { return it }
        val saved = runCatching {
            dir?.let { File(it, LINKS_FILE) }?.takeIf { it.exists() }?.readText()?.let { json.decodeFromString(LinkMap.serializer(), it).links }
        }.onFailure { Log.w(TAG, "Unreadable $LINKS_FILE: ${it.message}") }.getOrNull().orEmpty()
        return LinkedHashMap(saved).also { links = it }
    }

    private fun write(target: File, text: String) {
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) error("rename failed")
    }

    @kotlinx.serialization.Serializable
    private data class LinkMap(val links: Map<String, String>)
}
