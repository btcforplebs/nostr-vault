package com.nostrvault.ui.screens.music

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.music.WavlakeApi
import com.nostrvault.data.music.WavlakeTrack
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.PlayerTrack
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

// ── Songs in posts ──────────────────────────────────────────────

private val trackCache = mutableMapOf<String, WavlakeTrack>()

/**
 * A Wavlake song inside a post: artwork, title, artist and a play button,
 * in place of the generic link preview. Reposts and quotes of the song play
 * the same way. iOS: WavlakeTrackCard.
 */
@Composable
fun WavlakeTrackCard(
    trackId: String,
    modifier: Modifier = Modifier,
    /**
     * The link this card replaced. The note text no longer shows it, so a
     * track that fails to load falls back to it instead of vanishing.
     */
    fallbackUrl: String? = null,
) {
    var track by remember(trackId) { mutableStateOf(trackCache[trackId]) }
    var failed by remember(trackId) { mutableStateOf(false) }
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    LaunchedEffect(trackId) {
        if (track == null) {
            val found = runCatching { WavlakeApi.track(trackId) }.getOrNull()
            if (found != null) { trackCache[trackId] = found; track = found } else failed = true
        }
    }
    val t = track
    if (t == null) {
        if (!failed) {
            Box(modifier.fillMaxWidth().height(68.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)))
        } else if (fallbackUrl != null) {
            com.nostrvault.ui.components.LinkFallbackCard(fallbackUrl, modifier)
        }
        return
    }
    val isCurrent = current?.id == t.id
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)).padding(10.dp),
    ) {
        Artwork(t.albumArtUrl, 52.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(t.title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(t.artist, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("♪ Wavlake", color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        IconButton(onClick = { if (isCurrent) MusicPlayer.togglePlayPause() else MusicPlayer.play(listOf(t)) }, modifier = Modifier.size(48.dp)) {
            Icon(
                if (isCurrent && playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                contentDescription = if (isCurrent && playing) "Pause ${t.title}" else "Play ${t.title}",
                tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(40.dp),
            )
        }
    }
}

/**
 * An audio file shared in a post (an MP3 link): a play button on the
 * app-wide player, so it keeps going in the mini player, the notification
 * and on the lock screen like a Wavlake song. iOS: FeedAudioCard.
 */
@Composable
fun AudioFileCard(url: String, modifier: Modifier = Modifier) {
    val current by MusicPlayer.current.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val uri = remember(url) { android.net.Uri.parse(url) }
    val title = remember(url) {
        val name = uri.lastPathSegment.orEmpty().substringBeforeLast('.')
        // A Blossom hash, or no file name at all, says nothing to a person.
        val isHash = name.length == 64 && name.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        if (name.isBlank() || isHash) "Audio" else name
    }
    val ext = remember(url) { url.substringAfterLast('.').substringBefore('?').substringBefore('#').uppercase() }
    val host = uri.host.orEmpty()
    val isCurrent = current?.id == url
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)).padding(10.dp),
    ) {
        Box(
            Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)).background(accent.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.GraphicEq, contentDescription = null, tint = accent, modifier = Modifier.size(26.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (host.isNotEmpty()) Text(host, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("♪ $ext", color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        IconButton(
            onClick = {
                if (isCurrent) MusicPlayer.togglePlayPause()
                else MusicPlayer.playTracks(listOf(PlayerTrack(id = url, title = title, artist = host, artworkUrl = null, audioUrl = url, durationSec = null)))
            },
            modifier = Modifier.size(48.dp),
        ) {
            Icon(
                if (isCurrent && playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                contentDescription = if (isCurrent && playing) "Pause $title" else "Play $title",
                tint = accent, modifier = Modifier.size(40.dp),
            )
        }
    }
}
