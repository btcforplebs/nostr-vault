package com.nostrvault.data.music

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URI
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * A playable Wavlake track. Wavlake's public catalogue API returns direct MP3
 * links (`mediaUrl`), so the app plays them natively: in the background, with
 * lock-screen and notification controls. iOS: Models/Wavlake.swift.
 */
data class WavlakeTrack(
    val id: String,
    val title: String,
    val artist: String,
    val artistId: String? = null,
    val albumId: String? = null,
    val albumTitle: String? = null,
    val albumArtUrl: String? = null,
    val mediaUrl: String,
    val duration: Int? = null,
    val msatTotal: String? = null,
    /** The artist's Nostr key, when they've linked one on Wavlake. */
    val artistNpub: String? = null,
    val artistArtUrl: String? = null,
) {
    val pageUrl: String get() = "https://wavlake.com/track/$id"
    /** Sats earned, from Wavlake's millisat total. */
    val sats: Long? get() = msatTotal?.toLongOrNull()?.div(1000)
}

/** A Wavlake artist, as the music feed lists and opens them. iOS: WavlakeArtist. */
@kotlinx.serialization.Serializable
data class WavlakeArtist(
    val id: String,
    val name: String,
    val artUrl: String? = null,
    val npub: String? = null,
)

/** A Wavlake album, as an artist page lists it and an album page heads it. iOS: WavlakeAlbum. */
data class WavlakeAlbum(
    val id: String,
    val title: String,
    val artUrl: String? = null,
    val artist: String? = null,
    val artistId: String? = null,
    /** Release year, from Wavlake's ISO release date. */
    val year: Int? = null,
)

/** One row of a Wavlake search: a track, or an album or artist to open. */
sealed class WavlakeSearchResult {
    abstract val key: String
    data class Track(val track: WavlakeTrack) : WavlakeSearchResult() { override val key = "track:${track.id}" }
    data class Album(val id: String, val title: String, val artUrl: String?) : WavlakeSearchResult() { override val key = "album:$id" }
    data class Artist(val id: String, val name: String, val artUrl: String?) : WavlakeSearchResult() { override val key = "artist:$id" }
}

object WavlakeApi {
    const val BASE = "https://wavlake.com/api/v1/content"
    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    fun rankingsUrl(days: Int = 7) = "$BASE/rankings?sort=sats&days=$days"
    fun searchUrl(term: String): String =
        "$BASE/search".toHttpUrl().newBuilder().addQueryParameter("term", term).build().toString()
    fun trackUrl(id: String) = "$BASE/track/$id"
    fun albumUrl(id: String) = "$BASE/album/$id"
    fun artistUrl(id: String) = "$BASE/artist/$id"

    // ── Parsing ─────────────────────────────────────────────────

    private fun JsonObject.str(key: String): String? = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

    /** A track from any Wavlake payload. Rows without an http(s) MP3 link are dropped. */
    fun track(obj: JsonObject, artistFallback: String? = null): WavlakeTrack? {
        val id = obj.str("id") ?: return null
        val media = obj.str("mediaUrl") ?: return null
        val scheme = runCatching { URI(media).scheme?.lowercase() }.getOrNull()
        if (scheme != "https" && scheme != "http") return null
        val durationEl = obj["duration"] as? kotlinx.serialization.json.JsonPrimitive
        return WavlakeTrack(
            id = id,
            title = obj.str("title") ?: obj.str("name") ?: "Untitled",
            artist = obj.str("artist") ?: artistFallback ?: "Unknown artist",
            artistId = obj.str("artistId"),
            albumId = obj.str("albumId"),
            albumTitle = obj.str("albumTitle"),
            albumArtUrl = obj.str("albumArtUrl"),
            mediaUrl = media,
            duration = durationEl?.intOrNull ?: durationEl?.doubleOrNull?.toInt(),
            msatTotal = obj.str("msatTotal"),
            artistNpub = obj.str("artistNpub")?.takeIf { it.startsWith("npub1") },
            artistArtUrl = obj.str("artistArtUrl"),
        )
    }

    private fun parse(body: String): JsonElement? = runCatching { json.parseToJsonElement(body) }.getOrNull()

    fun tracksFromRankings(body: String): List<WavlakeTrack> =
        (parse(body) as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let(::track) } ?: emptyList()

    fun resultsFromSearch(body: String): List<WavlakeSearchResult> =
        (parse(body) as? JsonArray)?.mapNotNull { el ->
            val row = el as? JsonObject ?: return@mapNotNull null
            val id = row.str("id") ?: return@mapNotNull null
            val name = row.str("name") ?: row.str("title") ?: ""
            when (row.str("type")) {
                "track" -> track(row)?.let { WavlakeSearchResult.Track(it) }
                "album" -> WavlakeSearchResult.Album(id, name, row.str("albumArtUrl"))
                "artist" -> WavlakeSearchResult.Artist(id, name, row.str("artistArtUrl"))
                else -> null
            }
        } ?: emptyList()

    /** An album's tracks in album order; the album's artist fills in where a track has none. */
    fun tracksFromAlbum(body: String): List<WavlakeTrack> {
        val album = parse(body) as? JsonObject ?: return emptyList()
        val artist = album.str("artist")
        return (album["tracks"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let { t -> track(t, artist) } } ?: emptyList()
    }

    /** An album row or heading: title, cover, artist and year. */
    fun album(obj: JsonObject, artistFallback: String? = null): WavlakeAlbum? {
        val id = obj.str("id") ?: return null
        return WavlakeAlbum(
            id = id,
            title = obj.str("title") ?: obj.str("name") ?: "Untitled",
            artUrl = obj.str("albumArtUrl"),
            artist = obj.str("artist") ?: artistFallback,
            artistId = obj.str("artistId"),
            year = obj.str("releaseDate")?.take(4)?.toIntOrNull(),
        )
    }

    /** An album page's heading. */
    fun albumFromAlbum(body: String): WavlakeAlbum? = (parse(body) as? JsonObject)?.let { album(it) }

    /**
     * An artist's albums, newest release first. Wavlake lists them oldest
     * first; undated albums go last, and same-day albums keep their order.
     */
    fun albumsFromArtist(body: String): List<WavlakeAlbum> {
        val artist = parse(body) as? JsonObject ?: return emptyList()
        val name = artist.str("name")
        val rows = (artist["albums"] as? JsonArray)?.mapNotNull { el ->
            val row = el as? JsonObject ?: return@mapNotNull null
            album(row, name)?.let { it to (row.str("releaseDate") ?: "") }
        } ?: return emptyList()
        // ISO dates sort as strings; sortedByDescending is stable.
        return rows.sortedByDescending { it.second }.map { it.first }
    }

    /** An artist page's name, picture and Nostr key; only this endpoint carries the key. */
    fun artistFromArtist(body: String, id: String): WavlakeArtist? {
        val obj = parse(body) as? JsonObject ?: return null
        val name = obj.str("name") ?: obj.str("title") ?: ""
        if (name.isEmpty()) return null
        return WavlakeArtist(
            id = id,
            name = name,
            artUrl = obj.str("artistArtUrl"),
            npub = obj.str("artistNpub")?.takeIf { it.startsWith("npub1") },
        )
    }

    // ── Fetching ────────────────────────────────────────────────

    private suspend fun fetch(url: String): String = withContext(Dispatchers.IO) {
        client.newCall(Request.Builder().url(url).build()).execute().use { resp ->
            if (!resp.isSuccessful) throw java.io.IOException("Wavlake HTTP ${resp.code}")
            resp.body?.string() ?: ""
        }
    }

    /** Wavlake answers 1 to 90 days; anything longer is a 400. */
    suspend fun trending(days: Int = 7): List<WavlakeTrack> = tracksFromRankings(fetch(rankingsUrl(days)))
    suspend fun search(term: String): List<WavlakeSearchResult> = resultsFromSearch(fetch(searchUrl(term)))
    suspend fun track(id: String): WavlakeTrack? = tracksFromRankings(fetch(trackUrl(id))).firstOrNull()
    suspend fun album(id: String): List<WavlakeTrack> = tracksFromAlbum(fetch(albumUrl(id)))
    suspend fun artist(id: String): WavlakeArtist? = artistFromArtist(fetch(artistUrl(id)), id)

    /** An album's heading and tracks, from one request. */
    suspend fun albumPage(id: String): Pair<WavlakeAlbum?, List<WavlakeTrack>> {
        val body = fetch(albumUrl(id))
        return albumFromAlbum(body) to tracksFromAlbum(body)
    }

    /** An artist's details and albums (newest first), from one request. */
    suspend fun artistPage(id: String): Pair<WavlakeArtist?, List<WavlakeAlbum>> {
        val body = fetch(artistUrl(id))
        return artistFromArtist(body, id) to albumsFromArtist(body)
    }

    /** Every track on [albums], album by album in the order given; they load side by side, a failed one is left out. */
    suspend fun tracksOnAlbums(albums: List<WavlakeAlbum>): List<WavlakeTrack> = kotlinx.coroutines.coroutineScope {
        albums.map { a -> async { runCatching { album(a.id) }.getOrDefault(emptyList()) } }.awaitAll().flatten()
    }
}

/** Wavlake links as they appear in Nostr posts. */
object WavlakeLink {
    /** The track id in wavlake.com/track/<id> or embed.wavlake.com/track/<id>. */
    fun trackId(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        val host = uri.host?.lowercase() ?: return null
        if (host != "wavlake.com" && !host.endsWith(".wavlake.com")) return null
        val parts = (uri.path ?: "").split("/").filter { it.isNotEmpty() }
        if (parts.size < 2 || !parts[parts.size - 2].equals("track", ignoreCase = true)) return null
        val id = parts.last()
        return runCatching { UUID.fromString(id); id.lowercase() }.getOrNull()
            ?.takeIf { id.length == 36 }
    }

    /** What "Share" puts in the composer; an artist on Nostr is mentioned. */
    fun shareText(track: WavlakeTrack): String {
        val by = track.artistNpub?.let { "nostr:$it" } ?: track.artist
        return "🎵 ${track.title} by $by\n\nhttps://wavlake.com/track/${track.id}"
    }
}
