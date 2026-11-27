package com.nostrvault.service

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * File sizes learned by asking a server (`HEAD <url>`), kept by sha256. A
 * Blossom file's size never changes for a given hash, so an answer is kept
 * until the list is full; only the oldest are dropped. Only a real size is
 * stored: a failed or sizeless answer is asked again next time.
 *
 * Twins: Apple `Models/MediaSizeCache.swift` + `Services/MediaCache/MediaSizeLookup.swift`, web `net/blob-size.js`.
 */
@Serializable
data class MediaSizeCache(val entries: Map<String, Entry> = emptyMap()) {
    @Serializable
    data class Entry(val size: Long, /** Unix millis when learned (only to drop the oldest). */ val at: Long)

    companion object {
        const val MAX_ENTRIES = 20_000
        private val HASH = Regex("^[0-9a-f]{64}$")

        fun isHash(s: String): Boolean = HASH.matches(s)

        /**
         * The file size a HEAD answer gives, or null. Only a plain 200 counts: a 206 (a server treating it as a
         * range) says nothing about the whole file, and a missing, zero or unparsable Content-Length is unknown.
         */
        fun sizeOf(status: Int, contentLength: String?): Long? {
            if (status != 200) return null
            val n = contentLength?.trim()?.toLongOrNull() ?: return null
            return n.takeIf { it > 0 }
        }
    }

    fun size(hash: String): Long? = entries[hash.lowercase()]?.size

    fun storing(hash: String, size: Long, now: Long): MediaSizeCache {
        val key = hash.lowercase()
        if (!isHash(key) || size <= 0) return this
        return copy(entries = entries + (key to Entry(size, now)))
    }

    fun pruned(): MediaSizeCache =
        if (entries.size <= MAX_ENTRIES) this
        else MediaSizeCache(entries.entries.sortedByDescending { it.value.at }.take(MAX_ENTRIES).associate { it.key to it.value })
}

/**
 * Fills in the size of a media file no local source knows (a link in someone else's post, or a server that leaves
 * `size` out of its list) with one HEAD request, asked only for rows on screen and remembered on disk in
 * `cache/media_sizes.json`. Concurrent asks for one hash share one request. A null [file] keeps answers in memory
 * only (tests); [head] is the request seam (status, Content-Length).
 */
@Singleton
class BlobSizeLookup(
    private val file: File?,
    private val head: suspend (String) -> Pair<Int, String?>? = ::httpHead,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Inject constructor(@ApplicationContext context: Context) : this(File(context.cacheDir, FILE_NAME))

    companion object {
        private const val FILE_NAME = "media_sizes.json"
        private const val SAVE_DELAY_MS = 2_000L
        private val json = Json { ignoreUnknownKeys = true }

        // Same hosts as the images: share their connections ([ImageHttp]).
        private val client: OkHttpClient by lazy {
            ImageHttp.root.newBuilder()
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(5, TimeUnit.SECONDS)
                // A .fips host is a mesh name: never sent to DNS.
                .addInterceptor(com.nostrvault.fips.FipsHostGuard)
                .build()
        }

        private suspend fun httpHead(url: String): Pair<Int, String?>? = withContext(Dispatchers.IO) {
            runCatching {
                client.newCall(Request.Builder().url(url).head().build()).execute().use { it.code to it.header("Content-Length") }
            }.getOrNull()
        }
    }

    private val lock = Any()
    private var cache: MediaSizeCache? = null
    private val inFlight = HashMap<String, CompletableDeferred<Long?>>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null

    private fun loaded(): MediaSizeCache = synchronized(lock) {
        cache ?: (runCatching { file?.takeIf { it.exists() }?.readText()?.let { json.decodeFromString<MediaSizeCache>(it) } }
            .onFailure { Log.w("BlobSizeLookup", "Unreadable $FILE_NAME: ${it.message}") }
            .getOrNull() ?: MediaSizeCache()).also { cache = it }
    }

    /** The size already known for [hash], without asking anyone. Reads the file on first use: call off the main thread. */
    fun cached(hash: String): Long? = loaded().size(hash)

    /** The size of the file at [url] (content hash [hash]), asking its server once if not known. Null when none is given. */
    suspend fun size(hash: String, url: String): Long? {
        val key = hash.lowercase()
        if (!MediaSizeCache.isHash(key)) return null
        val scheme = url.substringBefore("://", "").lowercase()
        if (scheme != "https" && scheme != "http") return null
        val (mine, waiter) = synchronized(lock) {
            loaded().size(key)?.let { return it }
            inFlight[key]?.let { return@synchronized false to it }
            true to CompletableDeferred<Long?>().also { inFlight[key] = it }
        }
        if (!mine) return waiter.await()
        val result = try {
            head(url)?.let { (status, length) -> MediaSizeCache.sizeOf(status, length) }
        } catch (e: kotlinx.coroutines.CancellationException) {
            synchronized(lock) { inFlight.remove(key) }
            waiter.complete(null)
            throw e
        }
        synchronized(lock) {
            inFlight.remove(key)
            if (result != null) {
                cache = loaded().storing(key, result, clock())
                scheduleSave()
            }
        }
        waiter.complete(result)
        return result
    }

    private fun scheduleSave() {
        if (file == null) return
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(SAVE_DELAY_MS)
            val snapshot = synchronized(lock) { loaded().pruned().also { cache = it } }
            runCatching {
                val tmp = File(file.parentFile, "$FILE_NAME.tmp")
                tmp.writeText(json.encodeToString(MediaSizeCache.serializer(), snapshot))
                tmp.renameTo(file)
            }.onFailure { Log.w("BlobSizeLookup", "Could not save $FILE_NAME: ${it.message}") }
        }
    }
}
