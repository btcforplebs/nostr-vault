package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.model.BlossomUri
import com.nostrvault.service.BlossomUriLoader

/** Where a player stands with a `blossom:` link: its file being fetched and checked, ready, or nowhere. */
internal sealed interface Playable {
    data object Loading : Playable
    data class Ready(val uri: String) : Playable
    data object Unavailable : Playable
}

/**
 * What a player opens for [url]: the URL itself, or for a BUD-10 `blossom:`
 * link the local file whose bytes hash to it, so a video plays only from the
 * checked copy (iOS `VideoPlaybackService`, #1312).
 */
@Composable
internal fun rememberPlayable(url: String): State<Playable> {
    val context = LocalContext.current.applicationContext
    val initial = if (BlossomUri.isUri(url)) Playable.Loading else Playable.Ready(url)
    return produceState(initial, url) {
        if (value is Playable.Loading) {
            value = BlossomUriLoader.file(context, url)
                ?.let { Playable.Ready(android.net.Uri.fromFile(it).toString()) }
                ?: Playable.Unavailable
        }
    }
}

/** A player slot while a `blossom:` video is fetched, or once no server had it. */
@Composable
internal fun PlayableStatus(playable: Playable, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when (playable) {
            Playable.Loading -> CircularProgressIndicator(color = Color.White)
            Playable.Unavailable -> Text(MEDIA_UNAVAILABLE_TEXT, color = Color.White.copy(alpha = 0.85f))
            is Playable.Ready -> {}
        }
    }
}
