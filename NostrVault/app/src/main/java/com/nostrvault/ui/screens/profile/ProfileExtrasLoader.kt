package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.Reel
import com.nostrvault.data.music.WavlakeTrack
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.service.NostrService
import com.nostrvault.ui.screens.music.MusicFeedState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * One person's articles (kind 30023) and diVines (kind 34236) from the relays
 * the profile reads plus diVine's own relay, and their music from Wavlake.
 * Port of iOS ProfileExtrasLoader (ProfileView.swift).
 *
 * Wavlake can only be matched to a key through an artist's own page, so music
 * is found among the artists in recent rankings and the ones you've played: a
 * musician nobody has played lately has no Music tab yet.
 */
class ProfileExtrasLoader(
    private val scope: CoroutineScope,
    private val nostrService: NostrService,
) {
    private val _articles = MutableStateFlow<List<FeedNote>>(emptyList())
    val articles: StateFlow<List<FeedNote>> = _articles.asStateFlow()

    private val _reels = MutableStateFlow<List<Reel>>(emptyList())
    val reels: StateFlow<List<Reel>> = _reels.asStateFlow()

    private val _tracks = MutableStateFlow<List<WavlakeTrack>>(emptyList())
    val tracks: StateFlow<List<WavlakeTrack>> = _tracks.asStateFlow()

    private var loadedPubkey: String? = null
    private val jobs = mutableListOf<Job>()

    fun load(pubkey: String, relays: List<String>, force: Boolean = false) {
        if (pubkey.isEmpty() || (!force && loadedPubkey == pubkey)) return
        jobs.forEach { it.cancel() }
        jobs.clear()
        // A refresh of the same person keeps their tabs until new answers land.
        if (loadedPubkey != pubkey) {
            _articles.value = emptyList(); _reels.value = emptyList(); _tracks.value = emptyList()
        }
        loadedPubkey = pubkey
        jobs += scope.launch(Dispatchers.Default) { loadEvents(pubkey, relays) }
        jobs += scope.launch(Dispatchers.IO) { loadMusic(pubkey) }
    }

    private suspend fun loadEvents(pubkey: String, relays: List<String>) {
        val events = nostrService.queryRawEvents(
            filters = ProfileExtras.filters(pubkey),
            relayUrls = relays,
            timeoutMs = 8_000L,
        )
        if (loadedPubkey != pubkey) return
        // No answer at all is a failed fetch, not proof the tabs are empty.
        if (events.isEmpty() && (_articles.value.isNotEmpty() || _reels.value.isNotEmpty())) return
        val notes = events.mapNotNull { ev -> noteFrom(ev, pubkey) }
        _articles.value = ProfileExtras.articles(notes)
        _reels.value = ProfileExtras.reels(notes)
    }

    private fun noteFrom(ev: JsonObject, pubkey: String): FeedNote? {
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.contentOrNull
        val id = str("id") ?: return null
        if (str("pubkey") != pubkey) return null
        val kind = str("kind")?.toIntOrNull() ?: return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.map { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        } ?: return null
        if (!HavenBridge.verifyEvent(ev.toString())) return null
        return FeedNote.fromEvent(id, pubkey, str("content").orEmpty(), tags, createdAt, kind)
    }

    private suspend fun loadMusic(pubkey: String) {
        val (artists, _) = runCatching {
            MusicFeedState.followedArtists(setOf(pubkey), nostrService::npubToHex)
        }.getOrNull() ?: return
        val artist = artists.firstOrNull() ?: return
        if (loadedPubkey != pubkey) return
        val page = MusicFeedState.artistPage(artist.id) ?: return
        if (loadedPubkey != pubkey) return
        _tracks.value = page.tracks
    }
}

/** Pure parts of [ProfileExtrasLoader], for tests. */
object ProfileExtras {
    const val ARTICLE_KIND = 30023

    fun filters(pubkey: String): List<String> = listOf(
        """{"kinds":[$ARTICLE_KIND],"authors":["$pubkey"],"limit":100}""",
        """{"kinds":[${Reel.VIDEO_KINDS.joinToString(",")}],"authors":["$pubkey"],"limit":100}""",
    )

    /** `kind:pubkey:d`, the address every version of one event shares. */
    private fun address(note: FeedNote): String =
        "${note.kind}:${note.pubkey}:" + (note.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: "")

    /** Addressable: the newest version of each, newest first. */
    fun newestVersions(notes: List<FeedNote>): List<FeedNote> =
        notes.groupBy(::address)
            .map { (_, versions) -> versions.maxWith(compareBy<FeedNote> { it.createdAt }.thenBy { it.id }) }
            .sortedWith(compareByDescending<FeedNote> { it.createdAt }.thenByDescending { it.id })

    fun articles(notes: List<FeedNote>): List<FeedNote> =
        newestVersions(notes.filter { it.kind == ARTICLE_KIND })

    /** diVines that play, one per video file, newest first. */
    fun reels(notes: List<FeedNote>): List<Reel> =
        newestVersions(notes.filter { it.kind in Reel.VIDEO_KINDS })
            .mapNotNull { Reel.from(it, it.createdAt.time / 1000) }
            .distinctBy { it.videoUrl }
            .sortedWith(Reel.NEWEST_FIRST)

    /**
     * Where this person's articles and diVines are likely to be: your relay
     * when it is running, the feed relays, their outbox, and diVine's relay.
     */
    fun relays(ownRelay: String?, feedRelays: List<String>, outbox: List<String>): List<String> = buildList {
        ownRelay?.let { add(it) }
        addAll(feedRelays.ifEmpty { RelayConfiguration.FALLBACK_RELAYS }.take(3))
        addAll(outbox.take(3))
        add(Reel.DIVINE_RELAY)
    }.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
}
