package com.nostrvault.ui.screens.live

import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.PlayerTrack
import com.nostrvault.ui.navigation.DeepLinkTarget
import com.nostrvault.ui.navigation.PendingDeepLink
import com.nostrvault.ui.navigation.Screen

/**
 * Leaving the player for somewhere else in the app, with the stream's sound
 * carried on in the mini player. The player sits over the nav graph rather
 * than on a route (LiveStreamHost), so it asks the nav host to open the
 * destination through [PendingDeepLink], the way a widget or a notification does.
 */
internal object LiveStreamLeave {

    /**
     * The stream keeps playing as sound in the mini player and the notification.
     * [alreadyMini] is true when the mini player was playing this stream when the
     * screen opened: it simply carries on.
     */
    fun minimize(stream: LiveStream, hostName: String?, artworkUrl: String?, alreadyMini: Boolean) {
        if (alreadyMini) return
        val url = stream.streamingUrl ?: return
        MusicPlayer.playLive(
            stream,
            PlayerTrack(
                id = "live:${stream.address}",
                title = stream.title ?: "Live stream",
                artist = hostName ?: ("npub…" + stream.hostPubkey.takeLast(6)),
                artworkUrl = stream.imageUrl ?: stream.previewImageUrls.firstOrNull() ?: artworkUrl,
                audioUrl = url,
                durationSec = null,
                isLive = true,
                hostPubkey = stream.hostPubkey,
            ),
        )
    }

    /** Opens [pubkey]'s profile behind the player. The caller closes the player after. */
    fun openProfile(pubkey: String) {
        PendingDeepLink.post(DeepLinkTarget(Screen.Profile.createRoute(pubkey)))
    }

    /** Opens the composer with [text] in it. Nothing is posted until the user taps Post. */
    fun compose(text: String) {
        PendingDeepLink.post(DeepLinkTarget(Screen.ComposeNote.createRoute(text = text)))
    }
}
