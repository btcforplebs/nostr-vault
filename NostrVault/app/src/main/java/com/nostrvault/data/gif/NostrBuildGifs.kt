package com.nostrvault.data.gif

import com.nostrvault.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** One GIF from gifs.nostr.build. [url] is already hosted there, so it goes straight into a note. */
data class NostrBuildGif(
    val id: String,
    val url: String,
    val title: String,
    /** Width-fitted animated preview (≤240px) for the grid, or the still. */
    val previewUrl: String,
    val stillUrl: String?,
    val aspectRatio: Float,
)

/**
 * Client for the official gifs.nostr.build API
 * (https://gifs.nostr.build/developers/reference). Native apps identify with
 * an API key (`Authorization: Bearer gnb_…`) from a registered client; the key
 * comes from local.properties at build time and is empty when not set, in
 * which case the GIF button stays hidden. iOS: NostrBuildGifService.
 */
object NostrBuildGifs {
    const val BASE = "https://gifs.nostr.build/api/v1/"
    const val PAGE_SIZE = 24
    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    /** True when this build carries a key; otherwise the feature is off. */
    val isConfigured: Boolean get() = BuildConfig.NOSTR_BUILD_GIF_KEY.isNotBlank()

    sealed class GifError(message: String) : Exception(message) {
        object NotRegistered : GifError("nostr.build GIFs aren't switched on for this app yet")
        object RateLimited : GifError("nostr.build is busy, try again in a moment")
        class Unavailable(code: Int) : GifError("nostr.build GIFs are unavailable ($code)")
    }

    fun searchUrl(query: String, page: Int): String =
        "${BASE}search".toHttpUrl().newBuilder()
            .addQueryParameter("q", query)
            .addQueryParameter("limit", PAGE_SIZE.toString())
            .addQueryParameter("offset", (page * PAGE_SIZE).toString())
            .build().toString()

    suspend fun search(query: String, page: Int = 0): List<NostrBuildGif> = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(searchUrl(query, page))
            .header("Accept", "application/json")
            .header("Authorization", "Bearer ${BuildConfig.NOSTR_BUILD_GIF_KEY}")
            .build()
        client.newCall(request).execute().use { resp ->
            when (resp.code) {
                200 -> decode(resp.body?.string().orEmpty())
                403 -> throw GifError.NotRegistered
                429 -> throw GifError.RateLimited
                else -> throw GifError.Unavailable(resp.code)
            }
        }
    }

    private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.int(k: String) = (this[k] as? JsonPrimitive)?.intOrNull ?: 0

    /** Decodes a search page; split out so it can be tested without the network. */
    fun decode(body: String): List<NostrBuildGif> {
        val root = runCatching { json.parseToJsonElement(body) }.getOrNull() as? JsonObject ?: return emptyList()
        val items = root["items"] as? JsonArray ?: return emptyList()
        return items.mapNotNull { el ->
            val item = el as? JsonObject ?: return@mapNotNull null
            val id = item.str("id") ?: return@mapNotNull null
            val url = item.str("url")?.takeIf { it.startsWith("https://") } ?: return@mapNotNull null
            val w240 = (item["previews"] as? JsonObject)?.get("w240") as? JsonObject ?: return@mapNotNull null
            val still = w240.str("still") ?: return@mapNotNull null
            val preview = w240.str("animated") ?: still
            val w = w240.int("width").toFloat(); val h = w240.int("height").toFloat()
            val ratio = if (w > 0 && h > 0) w / h else {
                val iw = item.int("width").toFloat(); val ih = item.int("height").toFloat()
                if (ih > 0) iw / ih else 1f
            }
            NostrBuildGif(id, url, item.str("title").orEmpty(), preview, still, ratio.coerceIn(0.5f, 2.5f))
        }
    }
}
