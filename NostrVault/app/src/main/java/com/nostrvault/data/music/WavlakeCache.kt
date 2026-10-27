package com.nostrvault.data.music

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Wavlake answers kept between opens of the Music tab, and on disk so a
 * relaunch has them too. An answer younger than the caller's `maxAgeMs` is
 * used without asking Wavlake; an older one is still there to show while a
 * new one loads. One address asked for twice at once is one request.
 * iOS: WavlakeCache (Wavlake.swift).
 */
class WavlakeCache(
    /** Null keeps answers in memory only. */
    private val directory: File?,
    private val now: () -> Long = System::currentTimeMillis,
    private val loader: suspend (String) -> String,
) {
    data class Hit(val body: String, val fetchedAt: Long)

    private val lock = Mutex()
    private val memory = HashMap<String, Hit>()
    private val inFlight = HashMap<String, CompletableDeferred<String>>()

    /** What's kept for [url], however old; null when nothing is. */
    suspend fun stored(url: String): Hit? {
        lock.withLock { memory[url] }?.let { return it }
        val file = file(url) ?: return null
        val hit = withContext(Dispatchers.IO) {
            runCatching { if (file.isFile) Hit(file.readText(), file.lastModified()) else null }.getOrNull()
        } ?: return null
        lock.withLock { memory.getOrPut(url) { hit } }
        return hit
    }

    fun isFresh(hit: Hit, maxAgeMs: Long): Boolean = now() - hit.fetchedAt < maxAgeMs

    /** [url]'s answer: the kept one while younger than [maxAgeMs], otherwise a new one from Wavlake. */
    suspend fun data(url: String, maxAgeMs: Long): String {
        stored(url)?.takeIf { isFresh(it, maxAgeMs) }?.let { return it.body }
        return load(url)
    }

    /** Asks Wavlake for [url], joining a request for it already under way. */
    suspend fun load(url: String): String {
        var mine = false
        val pending = lock.withLock {
            inFlight[url] ?: CompletableDeferred<String>().also { inFlight[url] = it; mine = true }
        }
        if (!mine) return pending.await()
        try {
            val body = loader(url)
            keep(url, body)
            pending.complete(body)
            return body
        } catch (e: Throwable) {
            pending.completeExceptionally(e)
            throw e
        } finally {
            lock.withLock { inFlight.remove(url) }
        }
    }

    private suspend fun keep(url: String, body: String) {
        val date = now()
        lock.withLock { memory[url] = Hit(body, date) }
        val file = file(url) ?: return
        withContext(Dispatchers.IO) {
            runCatching {
                file.parentFile?.mkdirs()
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(body)
                // The file's date is when the answer came, so a relaunch knows its age.
                tmp.setLastModified(date)
                if (!tmp.renameTo(file)) tmp.delete()
            }
        }
    }

    /** One file per address, named by the address itself. */
    private fun file(url: String): File? = directory?.let { File(it, fileName(url)) }

    companion object {
        fun fileName(url: String): String =
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(url.toByteArray())
    }
}
