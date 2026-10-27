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

    /** How long each kind of answer is used before Wavlake is asked again. */
    object MaxAge {
        /** Rankings are sums of sats; ten minutes barely moves them. */
        const val RANKINGS = 10 * 60 * 1000L
        /** Albums and artist pages change when an artist uploads. */
        const val PAGE = 60 * 60 * 1000L
        /** An artist's name, picture and linked key, for Following. */
        const val ARTIST = 24 * 60 * 60 * 1000L
        /** A search typed again soon after. */
        const val SEARCH = 5 * 60 * 1000L
    }

    /** Rankings, albums and artists; on disk once [init] has run. */
    @Volatile private var cache = WavlakeCache(directory = null, loader = ::fetch)

    /** Searches, kept for this launch only. */
    private val searchCache = WavlakeCache(directory = null, loader = ::fetch)

    /** Keeps answers on disk between launches, in the app's cache folder. */
    fun init(context: android.content.Context) {
        cache = WavlakeCache(directory = java.io.File(context.cacheDir, "Wavlake"), loader = ::fetch)
    }

    /** A kept answer, parsed, and whether it's young enough to skip asking Wavlake again. */
    data class Kept<T>(val value: T, val isFresh: Boolean)

    /** What the cache holds for [url], without asking Wavlake. */
    private suspend fun <T> kept(url: String, maxAgeMs: Long, parse: (String) -> T): Kept<T>? {
        val hit = cache.stored(url) ?: return null
        return Kept(parse(hit.body), cache.isFresh(hit, maxAgeMs))
    }

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
    suspend fun trending(days: Int = 7): List<WavlakeTrack> =
        tracksFromRankings(cache.data(rankingsUrl(days), MaxAge.RANKINGS))
    suspend fun keptTrending(days: Int = 7): Kept<List<WavlakeTrack>>? =
        kept(rankingsUrl(days), MaxAge.RANKINGS, ::tracksFromRankings)
    suspend fun search(term: String): List<WavlakeSearchResult> =
        resultsFromSearch(searchCache.data(searchUrl(term), MaxAge.SEARCH))
    suspend fun track(id: String): WavlakeTrack? = tracksFromRankings(fetch(trackUrl(id))).firstOrNull()
    suspend fun album(id: String): List<WavlakeTrack> = tracksFromAlbum(cache.data(albumUrl(id), MaxAge.PAGE))
    suspend fun artist(id: String): WavlakeArtist? = artistFromArtist(cache.data(artistUrl(id), MaxAge.ARTIST), id)
    suspend fun keptArtist(id: String): Kept<WavlakeArtist?>? = kept(artistUrl(id), MaxAge.ARTIST) { artistFromArtist(it, id) }

    /** An album's heading and tracks, from one request. */
    suspend fun albumPage(id: String): Pair<WavlakeAlbum?, List<WavlakeTrack>> {
        val body = cache.data(albumUrl(id), MaxAge.PAGE)
        return albumFromAlbum(body) to tracksFromAlbum(body)
    }

    suspend fun keptAlbumPage(id: String): Kept<Pair<WavlakeAlbum?, List<WavlakeTrack>>>? =
        kept(albumUrl(id), MaxAge.PAGE) { albumFromAlbum(it) to tracksFromAlbum(it) }

    /** An artist's details and albums (newest first), from one request. */
    suspend fun artistPage(id: String): Pair<WavlakeArtist?, List<WavlakeAlbum>> {
        val body = cache.data(artistUrl(id), MaxAge.PAGE)
        return artistFromArtist(body, id) to albumsFromArtist(body)
    }

    suspend fun keptArtistPage(id: String): Kept<Pair<WavlakeArtist?, List<WavlakeAlbum>>>? =
        kept(artistUrl(id), MaxAge.PAGE) { artistFromArtist(it, id) to albumsFromArtist(it) }

    /** Every track on [albums], album by album in the order given; they load side by side, a failed one is left out. */
    suspend fun tracksOnAlbums(albums: List<WavlakeAlbum>): List<WavlakeTrack> = kotlinx.coroutines.coroutineScope {
        albums.map { a -> async { runCatching { album(a.id) }.getOrDefault(emptyList()) } }.awaitAll().flatten()
    }

    /** The kept tracks of [albums], without asking Wavlake; null unless every album is kept. */
    suspend fun keptTracksOnAlbums(albums: List<WavlakeAlbum>): Kept<List<WavlakeTrack>>? {
        val tracks = mutableListOf<WavlakeTrack>()
        var fresh = true
        for (a in albums) {
            val found = kept(albumUrl(a.id), MaxAge.PAGE, ::tracksFromAlbum) ?: return null
            tracks += found.value
            fresh = fresh && found.isFresh
        }
        return Kept(tracks, fresh)
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

/**
 * Music by someone the active account has blocked. Port of iOS
 * `WavlakeBlockFilter` (Wavlake.swift).
 *
 * Wavlake only names an artist's Nostr key on the artist's own page, so a
 * blocked artist is recognised two ways: by the key, when a song or a page
 * carries one, and otherwise by their Wavlake artist id once any page seen
 * this launch has named that key. Nothing is removed from Wavlake or from the
 * saved artist list, so an unblock shows them again.
 *
 * The gap this leaves: an artist never opened, played or followed has no known
 * key, so their songs can still rank in Trending until a page naming their key
 * is read.
 */
object WavlakeBlockFilter {
    /**
     * The Wavlake ids of every known artist whose linked key is blocked.
     * [hex] turns an npub into a hex pubkey, matching [blocked].
     */
    fun blockedArtistIds(known: List<WavlakeArtist>, blocked: Set<String>, hex: (String) -> String?): Set<String> {
        if (blocked.isEmpty()) return emptySet()
        val ids = HashSet<String>()
        for (artist in known) {
            val key = artist.npub?.let(hex) ?: continue
            if (key in blocked) ids.add(artist.id)
        }
        return ids
    }

    fun isBlocked(
        npub: String?,
        artistId: String?,
        blocked: Set<String>,
        artistIds: Set<String>,
        hex: (String) -> String?,
    ): Boolean {
        if (blocked.isEmpty() && artistIds.isEmpty()) return false
        if (npub != null && hex(npub) in blocked) return true
        return artistId != null && artistId in artistIds
    }

    fun tracks(
        tracks: List<WavlakeTrack>,
        blocked: Set<String>,
        artistIds: Set<String>,
        hex: (String) -> String?,
    ): List<WavlakeTrack> {
        if (blocked.isEmpty() && artistIds.isEmpty()) return tracks
        return tracks.filter { !isBlocked(it.artistNpub, it.artistId, blocked, artistIds, hex) }
    }

    fun artists(
        artists: List<WavlakeArtist>,
        blocked: Set<String>,
        artistIds: Set<String>,
        hex: (String) -> String?,
    ): List<WavlakeArtist> {
        if (blocked.isEmpty() && artistIds.isEmpty()) return artists
        return artists.filter { !isBlocked(it.npub, it.id, blocked, artistIds, hex) }
    }

    /**
     * One row of a search: the track rows by their own key or artist id, the
     * artist rows by id. Search carries no keys, so an artist row only drops
     * once a page has named their key.
     */
    fun results(
        results: List<WavlakeSearchResult>,
        blocked: Set<String>,
        artistIds: Set<String>,
        hex: (String) -> String?,
    ): List<WavlakeSearchResult> {
        if (blocked.isEmpty() && artistIds.isEmpty()) return results
        return results.filter { result ->
            when (result) {
                is WavlakeSearchResult.Track ->
                    !isBlocked(result.track.artistNpub, result.track.artistId, blocked, artistIds, hex)
                is WavlakeSearchResult.Artist -> result.id !in artistIds
                is WavlakeSearchResult.Album -> true
            }
        }
    }
}
