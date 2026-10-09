package com.nostrvault.relay

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/** What a Blossom address said when asked whether it takes uploads. */
enum class BlossomUploadSupport {
    ACCEPTS_UPLOADS,
    READ_ONLY,
    /** Plain http:// to a TLS port: Go answers a bare HTTP/1.0 400. */
    NEEDS_HTTPS,
    UNREACHABLE,
}

/**
 * Asks a Blossom server whether it takes uploads, with BUD-06 `HEAD /upload`
 * and no auth. A server that takes uploads answers 2xx, or refuses the
 * missing auth (401/403) or the missing size/type headers, and sets the
 * BUD-01 `X-Reason` header on errors. A read-only cache has no `/upload`
 * route: Morganite answers 400 with no `X-Reason` (its HEAD handler fails to
 * find a hash in "/upload"), others 404 or 405.
 */
object BlossomUploadProbe {
    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .build()

    fun classify(code: Int, hasReason: Boolean, http10: Boolean = false): BlossomUploadSupport = when {
        code == 400 && http10 && !hasReason -> BlossomUploadSupport.NEEDS_HTTPS
        code in 200..299 -> BlossomUploadSupport.ACCEPTS_UPLOADS
        hasReason -> BlossomUploadSupport.ACCEPTS_UPLOADS
        code == 401 || code == 403 || code == 411 || code == 413 || code == 415 ->
            BlossomUploadSupport.ACCEPTS_UPLOADS
        else -> BlossomUploadSupport.READ_ONLY
    }

    /** Blocking; call off the main thread. [baseUrl] is a normalized `http(s)://` address. */
    fun check(baseUrl: String): BlossomUploadSupport = try {
        val request = Request.Builder().url("${baseUrl.trimEnd('/')}/upload").head().build()
        client.newCall(request).execute().use { r ->
            classify(r.code, !r.header("X-Reason").isNullOrBlank(), r.protocol == okhttp3.Protocol.HTTP_1_0)
        }
    } catch (_: IOException) {
        BlossomUploadSupport.UNREACHABLE
    } catch (_: IllegalArgumentException) {
        BlossomUploadSupport.UNREACHABLE
    }
}
