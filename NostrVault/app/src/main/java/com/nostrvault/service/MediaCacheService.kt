package com.nostrvault.service

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import android.util.LruCache
import com.nostrvault.data.local.ConfigStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Comprehensive media caching system.
 * Handles local file resolution, thumbnail generation, download coalescing,
 * and 404 tracking.
 *
 * Port of MediaCacheService.swift.
 */
@Singleton
class MediaCacheService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "MediaCacheService"
        private const val IMAGE_CACHE_MAX_SIZE = 60 * 1024 * 1024 // 60 MB
        private const val THUMBNAIL_CACHE_MAX_SIZE = 24 * 1024 * 1024 // 24 MB (byte-sized, not count)
        private const val MAX_CONCURRENT_DOWNLOADS = 4
        private const val MAX_CONCURRENT_THUMBNAILS = 2
        private const val MIN_CACHE_SIZE = 100L // bytes
        private const val MAX_DOWNLOAD_BYTES = 50L * 1024 * 1024 // 50 MB hard ceiling per download
        private const val DISK_CACHE_MAX_BYTES = 256L * 1024 * 1024 // 256 MB on-disk cap
        private const val NOT_FOUND_MAX_AGE_MS = 7L * 24 * 3600 * 1000 // 404 flags expire after 7 days (iOS parity)
        // Files above this size are trusted without hashing.
        private const val INTEGRITY_MAX_HASH_BYTES = 64L * 1024 * 1024
    }

    // ── Caches ────────────────────────────────────────────────────────

    private val imageCache = object : LruCache<String, ByteArray>(IMAGE_CACHE_MAX_SIZE) {
        override fun sizeOf(key: String, value: ByteArray): Int = value.size
    }

    // Byte-sized, NOT count-sized: a count cap would let 200 native-resolution
    // video frames (~8 MB each at 1080p) balloon to >1 GB.
    private val thumbnailCache = object : LruCache<String, Bitmap>(THUMBNAIL_CACHE_MAX_SIZE) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
    }

    // ── Memory pressure eviction ─────────────────────────────────────

    /** Clear all in-memory caches (called on critical memory pressure). */
    fun evictMemoryCaches() {
        imageCache.evictAll()
        thumbnailCache.evictAll()
        Log.i(TAG, "Evicted all memory caches")
    }

    /** Trim in-memory caches to half capacity (called on moderate pressure). */
    fun trimMemoryCaches() {
        imageCache.trimToSize(IMAGE_CACHE_MAX_SIZE / 2)
        thumbnailCache.trimToSize(THUMBNAIL_CACHE_MAX_SIZE / 2)
        Log.i(TAG, "Trimmed memory caches to 50%")
    }

    // ── Directories ───────────────────────────────────────────────────

    val cacheDirectory: File by lazy {
        File(context.cacheDir, "media_cache").also { it.mkdirs() }
    }

    val thumbnailDirectory: File by lazy {
        File(context.cacheDir, "thumbnails").also { it.mkdirs() }
    }

    private var blossomDirectory: File? = null
    private var localHost: String? = null

    // ── Download coalescing ───────────────────────────────────────────

    private val inFlightDownloads = ConcurrentHashMap<String, Deferred<ByteArray?>>()
    private val inFlightThumbnails = ConcurrentHashMap<String, Deferred<Bitmap?>>()
    private val downloadSemaphore = Semaphore(MAX_CONCURRENT_DOWNLOADS)
    private val thumbnailSemaphore = Semaphore(MAX_CONCURRENT_THUMBNAILS)

    // ── 404 Tracking ──────────────────────────────────────────────────

    // URL → epoch-millis the 404 was observed. Entries expire after
    // NOT_FOUND_MAX_AGE_MS and are cleared by any successful fetch, so a blob
    // that 404'd once (e.g. mid-upload) doesn't stay flagged forever.
    private val notFoundURLs = ConcurrentHashMap<String, Long>()
    private val prefs by lazy {
        context.getSharedPreferences("media_cache_404", Context.MODE_PRIVATE)
    }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        // Load persisted 404s (dated format), migrating the legacy undated set.
        val cutoff = System.currentTimeMillis() - NOT_FOUND_MAX_AGE_MS
        val savedDated = prefs.getString("not_found_urls_dated", null)
        if (savedDated != null) {
            runCatching {
                val json = org.json.JSONObject(savedDated)
                for (key in json.keys()) {
                    val ts = json.optLong(key)
                    if (ts > cutoff) notFoundURLs[key] = ts
                }
            }
        } else {
            // Legacy format had no dates — stamp with now so entries age out normally.
            val now = System.currentTimeMillis()
            prefs.getStringSet("not_found_urls", emptySet())?.forEach { notFoundURLs[it] = now }
        }
        persistNotFound()

        // Disk eviction is otherwise never triggered — run it on startup so the
        // on-disk cache can't grow without bound (TTL sweep + byte-size cap).
        scope.launch {
            evictExpiredFiles()
            trimDiskCacheToSize(DISK_CACHE_MAX_BYTES)
        }
    }

    /**
     * Read a response body into memory with a hard byte ceiling. Rejects on an
     * oversized Content-Length and aborts mid-stream if the body exceeds [maxBytes].
     */
    private fun readBodyCapped(response: Response, maxBytes: Long): ByteArray? {
        val body = response.body ?: return null
        return body.use {
            if (it.contentLength() > maxBytes) {
                Log.w(TAG, "Rejecting oversized media body: ${it.contentLength()} > $maxBytes")
                return null
            }
            val source = it.source()
            val sink = okio.Buffer()
            var total = 0L
            while (true) {
                val n = source.read(sink, 64 * 1024L)
                if (n == -1L) break
                total += n
                if (total > maxBytes) {
                    Log.w(TAG, "Aborting oversized media body mid-stream at $total bytes")
                    return null
                }
            }
            // A body shorter than the advertised Content-Length is a truncated
            // transfer — caching it would poison every future local read.
            if (it.contentLength() >= 0 && total != it.contentLength()) {
                Log.w(TAG, "Rejecting truncated media body: $total of ${it.contentLength()} bytes")
                return null
            }
            sink.readByteArray()
        }
    }

    /** Delete oldest cached files until the media cache dir is under [maxBytes]. */
    private fun trimDiskCacheToSize(maxBytes: Long) {
        val files = cacheDirectory.listFiles()?.sortedBy { it.lastModified() } ?: return
        var total = files.sumOf { it.length() }
        for (file in files) {
            if (total <= maxBytes) break
            val size = file.length()
            if (file.delete()) total -= size
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Configuration
    // ══════════════════════════════════════════════════════════════════

    fun updateLocalHost(host: String?) {
        localHost = host
    }

    fun updateBlossomDirectory(dir: File?) {
        blossomDirectory = dir
    }

    // ══════════════════════════════════════════════════════════════════
    // In-memory image cache
    // ══════════════════════════════════════════════════════════════════

    fun cachedImage(url: String): ByteArray? = imageCache.get(hashUrl(url))

    fun cacheImage(data: ByteArray, url: String) {
        imageCache.put(hashUrl(url), data)
    }

    // ══════════════════════════════════════════════════════════════════
    // 404 Tracking
    // ══════════════════════════════════════════════════════════════════

    fun isKnown404(url: String): Boolean {
        val ts = notFoundURLs[url] ?: return false
        if (System.currentTimeMillis() - ts > NOT_FOUND_MAX_AGE_MS) {
            unmarkNotFound(url)
            return false
        }
        return true
    }

    fun markNotFound(url: String) {
        notFoundURLs[url] = System.currentTimeMillis()
        persistNotFound()
    }

    fun unmarkNotFound(url: String) {
        if (notFoundURLs.remove(url) != null) persistNotFound()
    }

    private fun persistNotFound() {
        val json = org.json.JSONObject()
        notFoundURLs.forEach { (url, ts) -> json.put(url, ts) }
        prefs.edit()
            .putString("not_found_urls_dated", json.toString())
            .remove("not_found_urls")
            .apply()
    }

    // ══════════════════════════════════════════════════════════════════
    // File path resolution
    // ══════════════════════════════════════════════════════════════════

    fun cachePath(url: String): File = File(cacheDirectory, hashUrl(url))

    fun isCached(url: String): Boolean = cachePath(url).exists()

    fun saveToCache(url: String, data: ByteArray) {
        if (data.size < MIN_CACHE_SIZE) return
        // Respect the user's "Disable Media Cache" advanced setting.
        if (configStore.config.value.disableMediaCache) return
        val file = cachePath(url)
        file.writeBytes(data)
    }

    fun loadFromCache(url: String): ByteArray? {
        val file = cachePath(url)
        return if (file.exists()) file.readBytes() else null
    }

    /**
     * Get local file URL for a remote URL.
     * Returns null for localhost URLs (to preserve MIME types).
     *
     * Hash-named files are integrity-checked before being returned: a
     * truncated/corrupt local copy (e.g. from an interrupted blob write) would
     * otherwise shadow a perfectly healthy remote URL forever.
     */
    fun localFileUrl(url: String): File? {
        if (isLocalUrl(url)) return null
        val hash = extractBlossomHash(url)

        // Try Blossom directory first
        if (hash != null) {
            blossomFile(forHash = hash)?.let { file ->
                verifiedHashNamedFile(file, hash)?.let { return it }
                // Corrupt blossom copy quarantined — fall through to the cache.
            }
        }

        // Try general cache
        val cached = cachePath(url)
        if (cached.exists()) {
            // Blossom-hash cache entries are named by the blob's content hash,
            // so they can be verified too. URL-keyed entries can't.
            return if (hash != null) verifiedHashNamedFile(cached, hash) else cached
        }
        return null
    }

    // ── Hash-named file integrity ─────────────────────────────────────

    /** Verification verdicts keyed by path|size|mtime — a rewritten file re-verifies. */
    private val integrityVerdicts = ConcurrentHashMap<String, Boolean>()

    /**
     * Returns [file] only if its content actually hashes to [expectedHash]
     * (memoized per launch). A mismatching file is discarded — deleted from the
     * cache, or quarantined with a `.corrupt` suffix in the Blossom store — so
     * callers fall through to the healthy remote URL and the copy can heal.
     */
    private fun verifiedHashNamedFile(file: File, expectedHash: String): File? {
        val size = file.length()
        if (size == 0L) {
            discardCorruptFile(file)
            return null
        }
        if (size > INTEGRITY_MAX_HASH_BYTES) return file

        val key = "${file.absolutePath}|$size|${file.lastModified()}"
        integrityVerdicts[key]?.let { return if (it) file else null }

        val digest = MessageDigest.getInstance("SHA-256")
        runCatching {
            file.inputStream().use { input ->
                val buf = ByteArray(1 shl 20)
                while (true) {
                    val n = input.read(buf)
                    if (n == -1) break
                    digest.update(buf, 0, n)
                }
            }
        }.onFailure { return null }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        val ok = actual == expectedHash
        integrityVerdicts[key] = ok

        if (!ok) {
            Log.w(TAG, "Corrupt local copy of ${expectedHash.take(8)}… (got ${actual.take(8)}…) — using remote")
            discardCorruptFile(file)
            return null
        }
        return file
    }

    /**
     * Cache entries are disposable and get deleted; Blossom blobs are relay data,
     * so they're quarantined under a `.corrupt` suffix instead — the relay stops
     * claiming the blob exists and a later re-mirror can heal it.
     */
    private fun discardCorruptFile(file: File) {
        val bDir = blossomDirectory
        if (bDir != null && file.absolutePath.startsWith(bDir.absolutePath)) {
            val quarantined = File(file.parentFile, "${file.name}.corrupt")
            quarantined.delete()
            file.renameTo(quarantined)
        } else {
            file.delete()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Blossom file resolution
    // ══════════════════════════════════════════════════════════════════

    fun blossomFile(named: String): File? {
        val dir = blossomDirectory ?: return null
        val file = File(dir, named)
        return if (file.exists()) file else null
    }

    fun blossomFile(forHash: String, extensionHint: String? = null): File? {
        val dir = blossomDirectory ?: return null
        if (forHash.length != 64) return null

        // Try exact hash match
        val exact = File(dir, forHash)
        if (exact.exists()) return exact

        // Try with common extensions
        val extensions = listOf(
            extensionHint, "jpg", "jpeg", "png", "gif", "webp",
            "mp4", "mov", "webm", "mp3", "wav",
        ).filterNotNull().distinct()

        for (ext in extensions) {
            val withExt = File(dir, "$forHash.$ext")
            if (withExt.exists()) return withExt
        }

        return null
    }

    fun isInLocalBlossom(hash: String): Boolean {
        if (hash.length != 64) return false
        return blossomFile(forHash = hash) != null
    }

    // ══════════════════════════════════════════════════════════════════
    // Download & fetch
    // ══════════════════════════════════════════════════════════════════

    /**
     * Download media with request coalescing.
     */
    suspend fun fetchData(url: String): ByteArray? {
        // Check memory cache
        cachedImage(url)?.let { return it }

        // Check disk cache
        loadFromCache(url)?.let { data ->
            cacheImage(data, url)
            return data
        }

        // Check if already downloading
        inFlightDownloads[url]?.let { return it.await() }

        // Start new download
        val deferred = scope.async {
            downloadSemaphore.acquire()
            try {
                val request = Request.Builder().url(url).get().build()
                val response = httpClient.newCall(request).execute()

                if (!response.isSuccessful) {
                    if (response.code == 404) markNotFound(url)
                    return@async null
                }

                val data = readBodyCapped(response, MAX_DOWNLOAD_BYTES) ?: return@async null
                saveToCache(url, data)
                cacheImage(data, url)
                // The URL is demonstrably alive — clear any stale 404 flag.
                unmarkNotFound(url)
                data
            } catch (e: Exception) {
                Log.w(TAG, "Download failed for $url: ${e.message}")
                null
            } finally {
                downloadSemaphore.release()
                inFlightDownloads.remove(url)
            }
        }

        inFlightDownloads[url] = deferred
        return deferred.await()
    }

    // ══════════════════════════════════════════════════════════════════
    // Video thumbnails
    // ══════════════════════════════════════════════════════════════════

    fun cachedThumbnail(url: String): Bitmap? {
        // Check memory
        thumbnailCache.get(hashUrl(url))?.let { return it }

        // Check disk
        val diskFile = File(thumbnailDirectory, "${hashUrl(url)}.jpg")
        if (diskFile.exists()) {
            val bitmap = android.graphics.BitmapFactory.decodeFile(diskFile.absolutePath)
            if (bitmap != null) {
                thumbnailCache.put(hashUrl(url), bitmap)
                return bitmap
            }
        }

        return null
    }

    /**
     * Generate a video thumbnail with coalescing.
     */
    suspend fun generateThumbnail(url: String): Bitmap? {
        // Check existing
        cachedThumbnail(url)?.let { return it }

        // Check if already generating
        inFlightThumbnails[url]?.let { return it.await() }

        val deferred = scope.async {
            thumbnailSemaphore.acquire()
            try {
                // Ensure file is local
                val localFile = localFileUrl(url)
                    ?: run {
                        fetchData(url)
                        cachePath(url).takeIf { it.exists() }
                    }
                    ?: return@async null

                renderThumbnail(localFile)?.also { bitmap ->
                    // Save to disk
                    val diskFile = File(thumbnailDirectory, "${hashUrl(url)}.jpg")
                    FileOutputStream(diskFile).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 75, out)
                    }
                    thumbnailCache.put(hashUrl(url), bitmap)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Thumbnail generation failed for $url: ${e.message}")
                null
            } finally {
                thumbnailSemaphore.release()
                inFlightThumbnails.remove(url)
            }
        }

        inFlightThumbnails[url] = deferred
        return deferred.await()
    }

    private fun renderThumbnail(file: File): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            // Try multiple time points
            val timePoints = listOf(0L, 1_000_000L, 3_000_000L) // 0s, 1s, 3s in microseconds
            for (timeUs in timePoints) {
                val frame = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                if (frame != null) return frame
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "MediaMetadataRetriever failed: ${e.message}")
            null
        } finally {
            retriever.release()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Source detection
    // ══════════════════════════════════════════════════════════════════

    enum class MediaSource { BLOSSOM, CACHED, REMOTE }

    fun getSource(url: String): MediaSource {
        val hash = extractBlossomHash(url)
        if (hash != null && isInLocalBlossom(hash)) return MediaSource.BLOSSOM
        if (isCached(url)) return MediaSource.CACHED
        return MediaSource.REMOTE
    }

    // ══════════════════════════════════════════════════════════════════
    // Cleanup
    // ══════════════════════════════════════════════════════════════════

    fun clearCache() {
        cacheDirectory.listFiles()?.forEach { it.delete() }
        imageCache.evictAll()
    }

    fun evictExpiredFiles(ttlDays: Int = configStore.config.value.cacheTTLDays) {
        // ttlDays <= 0 means "Never" — skip eviction entirely.
        if (ttlDays <= 0) return
        scope.launch {
            val cutoff = System.currentTimeMillis() - (ttlDays * 24 * 60 * 60 * 1000L)
            cacheDirectory.listFiles()?.forEach { file ->
                if (file.lastModified() < cutoff) file.delete()
            }
            thumbnailDirectory.listFiles()?.forEach { file ->
                if (file.lastModified() < cutoff) file.delete()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    fun isLocalUrl(url: String): Boolean {
        val lower = url.lowercase()
        return lower.contains("localhost") || lower.contains("127.0.0.1") ||
            (localHost != null && lower.contains(localHost!!.lowercase()))
    }

    fun hashUrl(url: String): String {
        // Check if URL contains a 64-char hex hash (Blossom)
        val hash = extractBlossomHash(url)
        if (hash != null) return hash

        // SHA-256 hash the URL
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun extractBlossomHash(url: String): String? {
        val path = url.substringAfterLast('/')
            .substringBefore('?')
            .substringBefore('.')
        return if (path.length == 64 && path.all { it in "0123456789abcdef" }) path else null
    }
}
