package com.nostrvault.service

import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Detects MIME content types for extensionless URLs (common with Blossom SHA256 hashes)
 * by issuing HTTP HEAD requests. Matches iOS MediaTypeDetector behaviour.
 *
 * Features:
 * - In-memory content-type cache (negligible RAM: short strings only)
 * - Request coalescing to prevent duplicate HEAD requests for the same URL
 * - 5-second timeout per request
 * - Zero body bytes downloaded (HEAD method)
 */
@Singleton
class MediaTypeDetector @Inject constructor() {

    private val contentTypeCache = ConcurrentHashMap<String, String>()
    private val inFlightDetections = ConcurrentHashMap<String, Deferred<String?>>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val httpClient = buildHttpClient()

    companion object {
        private val BLOSSOM_HASH_REGEX = Regex("[a-f0-9]{64}(\\.[a-z0-9]+)?", RegexOption.IGNORE_CASE)

        /** The HEAD-probe client. A seam so a test can check what it refuses. */
        // Same hosts as the images: share their connections ([ImageHttp]).
        internal fun buildHttpClient(): OkHttpClient = ImageHttp.root.newBuilder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            // A .fips host is a mesh name: never sent to DNS.
            .addInterceptor(com.nostrvault.fips.FipsHostGuard)
            .build()
    }

    /** Returns cached content type if available, null otherwise. */
    fun getCachedContentType(url: String): String? = contentTypeCache[url]

    /**
     * Detect the content type of a URL via HEAD request.
     * Coalesces concurrent requests for the same URL.
     */
    suspend fun detectContentType(url: String): String? {
        contentTypeCache[url]?.let { return it }

        // Coalesce: reuse in-flight request if one exists
        inFlightDetections[url]?.let { return it.await() }

        val deferred = scope.async {
            try {
                val request = Request.Builder()
                    .url(url)
                    .head()
                    .build()
                val response = httpClient.newCall(request).execute()
                response.use {
                    val contentType = it.header("Content-Type")
                    contentType?.also { ct -> contentTypeCache[url] = ct }
                }
            } catch (_: Exception) {
                null
            } finally {
                inFlightDetections.remove(url)
            }
        }

        inFlightDetections[url] = deferred
        return deferred.await()
    }

    /** Check if the URL path looks like a Blossom SHA256 hash (64 hex chars, optional extension). */
    fun isBlossom(url: String): Boolean {
        val lastSegment = url.substringAfterLast('/')
            .substringBefore('?')
        return BLOSSOM_HASH_REGEX.matches(lastSegment)
    }

    fun isImage(contentType: String): Boolean =
        contentType.lowercase().startsWith("image/")

    fun isVideo(contentType: String): Boolean =
        contentType.lowercase().startsWith("video/")

    fun isGIF(contentType: String): Boolean =
        contentType.lowercase().contains("image/gif")

}
