package com.nostrvault.service.music

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.music.WavlakeTrack
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Something the app-wide player can play: a Wavlake song, or a live stream's
 * sound. iOS: PlayerTrack in MusicPlayerService.swift.
 */
data class PlayerTrack(
    val id: String,
    val title: String,
    val artist: String,
    val artworkUrl: String?,
    val audioUrl: String,
    val durationSec: Int?,
    val isLive: Boolean = false,
    val albumTitle: String? = null,
    val pageUrl: String? = null,
    /** The song behind this item, for Share and the artist's profile. */
    val wavlake: WavlakeTrack? = null,
    /** A live stream's host, for opening their profile. */
    val hostPubkey: String? = null,
) {
    companion object {
        fun of(t: WavlakeTrack) = PlayerTrack(
            id = t.id, title = t.title, artist = t.artist, artworkUrl = t.albumArtUrl,
            audioUrl = t.mediaUrl, durationSec = t.duration, albumTitle = t.albumTitle,
            pageUrl = t.pageUrl, wavlake = t,
        )
    }
}

/**
 * The app's handle on [MusicPlaybackService]: queues tracks, and publishes
 * what's playing for the music screen and the mini player. Talks to the
 * service through a Media3 MediaController, so the notification, the lock
 * screen, headphones and the app all drive the same player.
 */
object MusicPlayer {
    private var controller: MediaController? = null
    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private var pending: (() -> Unit)? = null
    private var connecting = false

    /** The queue as the UI knows it; index-aligned with the player's items. */
    private var queue: List<PlayerTrack> = emptyList()

    private val _current = MutableStateFlow<PlayerTrack?>(null)
    val current: StateFlow<PlayerTrack?> = _current.asStateFlow()
    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    private val _isBuffering = MutableStateFlow(false)
    val isBuffering: StateFlow<Boolean> = _isBuffering.asStateFlow()
    private val _positionMs = MutableStateFlow(0L)
    val positionMs: StateFlow<Long> = _positionMs.asStateFlow()
    private val _durationMs = MutableStateFlow(0L)
    val durationMs: StateFlow<Long> = _durationMs.asStateFlow()
    private val _hasNext = MutableStateFlow(false)
    val hasNext: StateFlow<Boolean> = _hasNext.asStateFlow()

    /** The queue is in shuffled order; turning it off puts back the order it was played in. */
    private val _isShuffled = MutableStateFlow(false)
    val isShuffled: StateFlow<Boolean> = _isShuffled.asStateFlow()
    /** The queue's order before shuffle, while shuffle is on. */
    private var unshuffledQueue: List<PlayerTrack> = emptyList()

    /** The queue in play order, and where the player is in it, for Up Next. */
    private val _queueState = MutableStateFlow<List<PlayerTrack>>(emptyList())
    val queueState: StateFlow<List<PlayerTrack>> = _queueState.asStateFlow()
    private val _index = MutableStateFlow(0)
    val index: StateFlow<Int> = _index.asStateFlow()

    /** Kept across queues; a live stream ignores it. */
    private val _repeatMode = MutableStateFlow(MusicRepeatMode.OFF)
    val repeatMode: StateFlow<MusicRepeatMode> = _repeatMode.asStateFlow()
    /** The stream whose sound is playing, so the full player can offer Watch. */
    private val _liveStream = MutableStateFlow<LiveStream?>(null)
    val liveStream: StateFlow<LiveStream?> = _liveStream.asStateFlow()

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Connects to the service on first use, then runs [action]. */
    private fun withController(action: (MediaController) -> Unit) {
        controller?.let { action(it); return }
        pending = { controller?.let(action) }
        if (connecting) return
        val ctx = appContext ?: return
        connecting = true
        val token = SessionToken(ctx, ComponentName(ctx, MusicPlaybackService::class.java))
        val future = MediaController.Builder(ctx, token).buildAsync()
        future.addListener({
            connecting = false
            val c = runCatching { future.get() }.getOrNull() ?: return@addListener
            controller = c
            c.addListener(listener)
            sync()
            pending?.invoke()
            pending = null
        }, MoreExecutors.directExecutor())
    }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) = sync()

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            pausedByInterruption = !playWhenReady &&
                reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS &&
                !appInForeground &&
                _current.value?.isLive == true
        }
    }

    /**
     * Set when another app took the sound from a playing live stream while
     * this app was in the background, so coming back carries on with it
     * ([setAppInForeground]). The app's own videos take the sound only while
     * it is in front, and the mini player stays paused for those, as it does
     * for songs and for anything the owner paused.
     */
    private var pausedByInterruption = false
    private var appInForeground = false

    /** Called from MainActivity's onStart/onStop. */
    fun setAppInForeground(foreground: Boolean) {
        appInForeground = foreground
        if (!foreground || !pausedByInterruption) return
        pausedByInterruption = false
        val c = controller ?: return
        if (_current.value?.isLive != true || c.playWhenReady) return
        if (c.playbackState == Player.STATE_IDLE) c.prepare()
        c.play()
    }

    private val ticker = object : Runnable {
        override fun run() {
            val c = controller ?: return
            _positionMs.value = c.currentPosition.coerceAtLeast(0)
            val d = c.duration
            if (d > 0) _durationMs.value = d
            if (c.isPlaying) main.postDelayed(this, 500)
        }
    }

    private fun sync() {
        val c = controller ?: return
        val idx = c.currentMediaItemIndex
        _current.value = if (c.mediaItemCount > 0) queue.getOrNull(idx) else null
        _queueState.value = queue
        _index.value = idx
        _isPlaying.value = c.isPlaying
        _isBuffering.value = c.playbackState == Player.STATE_BUFFERING
        _hasNext.value = c.hasNextMediaItem() && queue.getOrNull(idx)?.isLive != true
        _positionMs.value = c.currentPosition.coerceAtLeast(0)
        _durationMs.value = c.duration.takeIf { it > 0 }
            ?: ((queue.getOrNull(idx)?.durationSec ?: 0) * 1000L)
        main.removeCallbacks(ticker)
        if (c.isPlaying) main.post(ticker)
    }

    private fun item(t: PlayerTrack): MediaItem = MediaItem.Builder()
        .setMediaId(t.id)
        .setUri(t.audioUrl)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(t.title)
                .setArtist(t.artist)
                .setAlbumTitle(t.albumTitle)
                .setArtworkUri(t.artworkUrl?.let(Uri::parse))
                .setIsPlayable(true)
                .build(),
        )
        .build()

    /** Plays Wavlake [tracks] from [startIndex]; the rest queue up after it. */
    fun play(tracks: List<WavlakeTrack>, startIndex: Int = 0) =
        playTracks(tracks.map(PlayerTrack::of), startIndex)

    /**
     * Listens to a live stream: sound only, in the mini player and the
     * notification. Replaces whatever was queued. iOS: playLive(stream:item:).
     */
    fun playLive(stream: LiveStream, track: PlayerTrack) {
        playTracks(listOf(track), 0)
        _liveStream.value = stream
    }

    fun playTracks(tracks: List<PlayerTrack>, startIndex: Int = 0) {
        if (tracks.isEmpty()) return
        _liveStream.value = null
        queue = tracks
        _isShuffled.value = false
        unshuffledQueue = emptyList()
        _current.value = tracks.getOrNull(startIndex)
        withController { c ->
            c.setMediaItems(tracks.map(::item), startIndex.coerceIn(0, tracks.lastIndex), 0L)
            applyRepeat(c)
            c.prepare()
            c.play()
        }
    }

    /**
     * Plays [tracks] in a random order, with shuffle showing as on, so
     * turning it off goes back to the list's own order.
     */
    fun playShuffled(tracks: List<WavlakeTrack>) {
        if (tracks.isEmpty()) return
        val ordered = tracks.map(PlayerTrack::of)
        playTracks(ordered.shuffled(), 0)
        unshuffledQueue = ordered
        _isShuffled.value = true
    }

    /**
     * Shuffles everything but the song playing, which keeps playing at the
     * top; off, the original order comes back with the current song in
     * place. The playing item is never touched, so the song doesn't skip.
     */
    fun toggleShuffle() = withController { c ->
        val idx = c.currentMediaItemIndex
        val playing = queue.getOrNull(idx) ?: return@withController
        if (playing.isLive || c.mediaItemCount != queue.size) return@withController
        val (newQueue, newIndex) = if (_isShuffled.value) {
            MusicQueueOrder.unshuffle(unshuffledQueue, queue, playing.id) { it.id }
                .also { unshuffledQueue = emptyList() }
        } else {
            unshuffledQueue = queue
            MusicQueueOrder.shuffleAround(queue, idx) to 0
        }
        queue = newQueue
        _isShuffled.value = !_isShuffled.value
        // Everything around the playing item goes, then the new order is
        // put back before and after it.
        if (idx + 1 < c.mediaItemCount) c.removeMediaItems(idx + 1, c.mediaItemCount)
        if (idx > 0) c.removeMediaItems(0, idx)
        val before = newQueue.subList(0, newIndex)
        val after = newQueue.subList(newIndex + 1, newQueue.size)
        if (after.isNotEmpty()) c.addMediaItems(after.map(::item))
        if (before.isNotEmpty()) c.addMediaItems(0, before.map(::item))
        sync()
    }

    /** Plays the queue's song at [position], from Up Next. */
    fun jump(position: Int) = withController { c ->
        if (position !in 0 until c.mediaItemCount || position == c.currentMediaItemIndex) return@withController
        c.seekToDefaultPosition(position)
        if (c.playbackState == Player.STATE_IDLE) c.prepare()
        c.play()
    }

    /** Off → repeat all → repeat one → off. */
    fun cycleRepeat() {
        _repeatMode.value = _repeatMode.value.next()
        withController { c -> applyRepeat(c); sync() }
    }

    /** The owner's repeat choice, except on a live stream, which has no end to go round from. */
    private fun applyRepeat(c: MediaController) {
        val live = queue.getOrNull(c.currentMediaItemIndex)?.isLive == true
        c.repeatMode = if (live) Player.REPEAT_MODE_OFF else when (_repeatMode.value) {
            MusicRepeatMode.OFF -> Player.REPEAT_MODE_OFF
            MusicRepeatMode.ALL -> Player.REPEAT_MODE_ALL
            MusicRepeatMode.ONE -> Player.REPEAT_MODE_ONE
        }
    }

    fun togglePlayPause() = withController { c ->
        if (c.isPlaying) {
            c.pause()
        } else {
            // A failed item is loaded again; a live one then rejoins the
            // broadcast where it is now (LiveRejoinListener in the service).
            if (c.playbackState == Player.STATE_IDLE) c.prepare()
            c.play()
        }
    }
    fun pause() = withController { it.pause() }
    fun next() = withController { if (it.hasNextMediaItem()) it.seekToNextMediaItem() }

    /** Back to the previous song, or to the start of this one after a few seconds. */
    fun previous() = withController { c ->
        if (_current.value?.isLive == true) return@withController
        if (c.currentPosition > 3000 || !c.hasPreviousMediaItem()) c.seekTo(0) else c.seekToPreviousMediaItem()
    }

    fun seekTo(ms: Long) = withController { it.seekTo(ms.coerceAtLeast(0)) }

    /** Stops and clears the queue; the mini player goes away. */
    fun stop() {
        queue = emptyList()
        _isShuffled.value = false
        unshuffledQueue = emptyList()
        _liveStream.value = null
        _current.value = null
        withController { c ->
            c.stop()
            c.clearMediaItems()
        }
    }
}
