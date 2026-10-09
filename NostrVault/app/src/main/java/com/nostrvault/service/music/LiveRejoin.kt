package com.nostrvault.service.music

import androidx.media3.common.PlaybackException
import androidx.media3.common.Player

/**
 * Puts a live stream back on the broadcast as it is now. A live item left
 * paused falls behind the live window — backgrounded, or stopped by another
 * app's sound — and playing it from there fails with
 * [PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW]. The default position of a
 * live window is its live edge; a player stopped by an error is prepared again.
 * iOS: VideoPlaybackService.rejoinLive, MusicPlayerService.resume.
 */
fun Player.rejoinLiveEdge() {
    seekToDefaultPosition()
    if (playbackState == Player.STATE_IDLE) prepare()
}

/**
 * Keeps a player on the live edge: Play on a live item rejoins the broadcast
 * instead of resuming where it was paused, and an item that fell behind the
 * live window is reloaded at the edge rather than left failed.
 */
class LiveRejoinListener(private val player: Player) : Player.Listener {
    override fun onPlayerError(error: PlaybackException) {
        if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) player.rejoinLiveEdge()
    }

    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        if (playWhenReady &&
            reason == Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST &&
            player.isCurrentMediaItemLive
        ) {
            player.rejoinLiveEdge()
        }
    }
}
