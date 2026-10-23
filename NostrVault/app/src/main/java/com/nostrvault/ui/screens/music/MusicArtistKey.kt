package com.nostrvault.ui.screens.music

import com.nostrvault.data.music.WavlakeApi
import com.nostrvault.data.music.WavlakeArtist
import com.nostrvault.data.music.WavlakeLink
import com.nostrvault.data.music.WavlakeTrack
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap

/**
 * A song's artist's Nostr key. Rankings and search leave it off the song, so it comes from an artist
 * already seen, else from Wavlake's artist page. Each artist is looked up once a launch, a "no key"
 * answer included. iOS: MusicArtistKey (MusicSheetHost.swift, #1084).
 */
object MusicArtistKey {
    /** Wavlake's answer per artist id: their npub, or "" for none. */
    private val looked = ConcurrentHashMap<String, String>()

    /** Seams for the tests. */
    internal var fetchArtist: suspend (String) -> WavlakeArtist? = { WavlakeApi.artist(it) }
    internal var knownArtists: () -> List<WavlakeArtist> = { MusicFeedState.knownArtists() }
    internal fun forget() = looked.clear()

    /** Share waits this long for Wavlake, then shares without the mention. */
    internal var shareWaitMs = 3_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    suspend fun npub(track: WavlakeTrack): String? {
        track.artistNpub?.let { return it }
        val id = track.artistId ?: return null
        knownArtists().firstOrNull { it.id == id && it.npub != null }?.let { return it.npub }
        looked[id]?.let { return it.ifEmpty { null } }
        return try {
            fetchArtist(id)?.npub.also { looked[id] = it.orEmpty() }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null // offline: ask again next time
        }
    }

    /**
     * The post a song is shared as, the artist mentioned as `nostr:npub…` (which the composer posts with
     * a `p` tag) whenever they have a key.
     */
    suspend fun shareText(track: WavlakeTrack): String {
        val npub = withTimeoutOrNull(shareWaitMs) { npub(track) }
        return WavlakeLink.shareText(track.copy(artistNpub = npub ?: track.artistNpub))
    }

    /**
     * Opens the composer through [onShare] once the text is ready. On the app's scope, not a sheet's:
     * the sheet that offered Share is dismissed as the tap lands.
     */
    fun share(track: WavlakeTrack, onShare: (String) -> Unit) {
        scope.launch { onShare(shareText(track)) }
    }
}
