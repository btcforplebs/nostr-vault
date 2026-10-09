package com.nostrvault.service.music

import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Test

class LiveRejoinListenerTest {

    private fun player(live: Boolean, state: Int = Player.STATE_READY): Player = mockk(relaxed = true) {
        every { isCurrentMediaItemLive } returns live
        every { playbackState } returns state
    }

    @Test fun `play on a live item rejoins the live edge`() {
        val p = player(live = true)
        LiveRejoinListener(p).onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        verify { p.seekToDefaultPosition() }
        verify(exactly = 0) { p.prepare() }
    }

    @Test fun `play on a song resumes where it was`() {
        val p = player(live = false)
        LiveRejoinListener(p).onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        verify(exactly = 0) { p.seekToDefaultPosition() }
    }

    @Test fun `audio focus coming back is not a rejoin by itself`() {
        val p = player(live = true)
        LiveRejoinListener(p).onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS)
        verify(exactly = 0) { p.seekToDefaultPosition() }
    }

    @Test fun `falling behind the live window reloads at the edge`() {
        val p = player(live = true, state = Player.STATE_IDLE)
        LiveRejoinListener(p).onPlayerError(
            PlaybackException("behind", null, PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW),
        )
        verify { p.seekToDefaultPosition() }
        verify { p.prepare() }
    }

    @Test fun `other errors are left alone`() {
        val p = player(live = true, state = Player.STATE_IDLE)
        LiveRejoinListener(p).onPlayerError(
            PlaybackException("gone", null, PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS),
        )
        verify(exactly = 0) { p.seekToDefaultPosition() }
        verify(exactly = 0) { p.prepare() }
    }
}
