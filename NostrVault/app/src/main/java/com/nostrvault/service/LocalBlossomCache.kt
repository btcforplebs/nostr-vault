package com.nostrvault.service

import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Loads Blossom media through a local Blossom cache app on this phone
 * (Morganite, greenart7c3/Morganite), when one is running.
 *
 * Morganite listens on 127.0.0.1:24242 and serves `GET /<sha256>[.ext]`.
 * On a miss it fetches the blob from the `?xs=<server>` hint (BUD-10), keeps
 * a copy and streams it back, so media seen once loads from the phone after
 * that, offline too. It takes no uploads, so it only ever sits on the read
 * path.
 *
 * Any app on the phone can listen on that port, so nothing it returns is
 * trusted: the body is read in full and kept only if its SHA-256 matches the
 * hash in the URL. Any failure (cache not running, blob not found, wrong
 * hash, too big to check) falls back to the original URL, so a missing cache
 * costs one refused loopback connect, at most once per [PROBE_TTL_MS].
 */
object LocalBlossomCache {
    const val BASE_URL = "http://127.0.0.1:24242"
    private const val PROBE_TTL_MS = 30_000L
    /** Larger blobs are not buffered for the hash check; they load from the origin. */
    private const val MAX_VERIFY_BYTES = 32L * 1024 * 1024

    /** Set from config (Advanced → Media → Use Local Blossom Cache). */
    @Volatile var enabled: Boolean = true

    @Volatile private var lastProbeAt = 0L
    @Volatile private var lastProbeUp = false

    private val probeClient = OkHttpClient.Builder()
        .connectTimeout(300, TimeUnit.MILLISECONDS)
        .readTimeout(1, TimeUnit.SECONDS)
        .build()

    private val blobSegment = Regex("^[0-9a-f]{64}(\\.[a-z0-9]{1,8})?$")

    /**
     * The cache URL for [url], or null when it is not a Blossom blob URL
     * (last path segment `<sha256>[.ext]`) or already points at this phone.
     */
    fun cacheUrlFor(url: String): String? {
        val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = uri.host?.lowercase() ?: return null
        if (host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]") return null
        val segment = uri.rawPath?.substringAfterLast('/')?.lowercase() ?: return null
        if (!blobSegment.matches(segment)) return null
        val origin = buildString {
            append(scheme).append("://").append(uri.rawAuthority)
            val dir = uri.rawPath.substringBeforeLast('/')
            if (dir.isNotEmpty()) append(dir)
        }
        return "$BASE_URL/$segment?xs=" + java.net.URLEncoder.encode(origin, "UTF-8")
    }

    /** Whether the cache answered `HEAD /` recently. Blocking; call off the main thread. */
    fun isRunning(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastProbeAt < PROBE_TTL_MS) return lastProbeUp
        val up = try {
            probeClient.newCall(Request.Builder().url("$BASE_URL/").head().build())
                .execute().use { it.isSuccessful }
        } catch (_: IOException) {
            false
        }
        lastProbeUp = up
        lastProbeAt = now
        return up
    }

    private fun markDown() {
        lastProbeUp = false
        lastProbeAt = System.currentTimeMillis()
    }

    /** The `<sha256>` in a blob URL's last path segment, or null. */
    private fun blobHash(url: String): String? =
        url.substringBefore('?').substringAfterLast('/').substringBefore('.').lowercase()
            .takeIf { it.length == 64 && it.all { c -> c in "0123456789abcdef" } }

    private fun sha256Hex(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    /**
     * OkHttp application interceptor: try the cache first, then the original
     * URL. The cache gets its own short timeouts so a slow miss leaves the
     * fallback time inside the caller's call timeout.
     */
    val interceptor = Interceptor { chain ->
        val original = chain.request()
        val cacheUrl = if (enabled && original.method == "GET" && original.header("Range") == null) {
            cacheUrlFor(original.url.toString())
        } else null
        val expected = cacheUrl?.let { blobHash(original.url.toString()) }
        if (cacheUrl == null || expected == null || !isRunning()) return@Interceptor chain.proceed(original)

        val verified: Response? = try {
            chain.withConnectTimeout(500, TimeUnit.MILLISECONDS)
                .withReadTimeout(8, TimeUnit.SECONDS)
                .proceed(original.newBuilder().url(cacheUrl).build())
                .use { r ->
                    val body = r.body
                    val length = body?.contentLength() ?: -1L
                    if (!r.isSuccessful || body == null || length > MAX_VERIFY_BYTES) return@use null
                    val bytes = body.source().use { src ->
                        // Unknown length: read at most the cap plus one byte.
                        src.request(MAX_VERIFY_BYTES + 1)
                        if (src.buffer.size > MAX_VERIFY_BYTES) null else src.buffer.readByteArray()
                    } ?: return@use null
                    if (sha256Hex(bytes) != expected) return@use null
                    r.newBuilder()
                        .body(bytes.toResponseBody(body.contentType()))
                        .build()
                }
        } catch (_: java.net.ConnectException) {
            markDown()
            null
        } catch (_: IOException) {
            null
        }
        verified ?: chain.proceed(original)
    }
}
