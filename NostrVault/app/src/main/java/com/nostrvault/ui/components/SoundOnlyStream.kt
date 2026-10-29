package com.nostrvault.ui.components

import androidx.media3.common.C
import androidx.media3.common.Player

/**
 * A live stream heard and not seen: no picture is decoded, and the player
 * takes the stream's smallest variant. With only the video track off, an HLS
 * stream still downloaded its full-size variant (1.5–3 Mbps) for a sound
 * nobody could see. iOS `SoundOnlyStream`.
 */
fun Player.setSoundOnly(soundOnly: Boolean) {
    trackSelectionParameters = trackSelectionParameters.buildUpon()
        .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, soundOnly)
        .setForceLowestBitrate(soundOnly)
        .build()
}
