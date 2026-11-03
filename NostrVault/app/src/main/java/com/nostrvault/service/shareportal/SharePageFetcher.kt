package com.nostrvault.service.shareportal

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Fetches a shared page's HTML so the app (never the share sheet) can read its
 * JSON-LD Recipe or Event: GET, http(s) only, text/html only, 3 MB cap, 15 s.
 * Twin: SharePageFetcher.swift.
 */
@Singleton
class SharePageFetcher @Inject constructor() {
    private val http = OkHttpClient.Builder()
        .callTimeout(15, TimeUnit.SECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    suspend fun html(url: String): String? = withContext(Dispatchers.IO) {
        if (!isWeb(url)) return@withContext null
        runCatching {
            val request = Request.Builder().url(url).get().header("Accept", "text/html").build()
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val type = response.header("Content-Type").orEmpty().lowercase()
                if (!type.startsWith("text/html")) return@use null
                val body = response.body ?: return@use null
                val source = body.source()
                // Read at most MAX_BYTES + 1 so an oversize page is refused, not cut.
                source.request(MAX_BYTES + 1)
                if (source.buffer.size > MAX_BYTES) return@use null
                source.buffer.readString(body.contentType()?.charset() ?: Charsets.UTF_8)
            }
        }.getOrNull()
    }

    companion object {
        const val MAX_BYTES = 3L * 1024 * 1024
        fun isWeb(url: String): Boolean {
            val l = url.trim().lowercase()
            return l.startsWith("https://") || l.startsWith("http://")
        }
    }
}
