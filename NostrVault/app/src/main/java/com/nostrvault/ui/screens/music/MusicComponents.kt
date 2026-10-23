package com.nostrvault.ui.screens.music

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.music.WavlakeTrack
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

@Composable
fun MusicSpinner() {
    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = LocalNostrVaultColors.current.primary)
    }
}

@Composable
fun MusicBackButton(onBack: () -> Unit = MusicFeedState::goBack) {
    Box(Modifier.fillMaxWidth()) {
        TextButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(4.dp))
            Text("Back")
        }
    }
}

@Composable
fun MusicSectionTitle(title: String) {
    Text(
        title, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(top = 8.dp, bottom = 8.dp).semantics { heading() },
    )
}

@Composable
fun MusicRetryMessage(text: String, retry: () -> Unit) {
    Text(
        text, color = SecondaryText, fontSize = 14.sp, textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().clickable(onClick = retry).padding(vertical = 30.dp),
    )
}

/** Play from the top and Shuffle, plus any extra pill. Disabled until there are songs. iOS: MusicPlayButtons. */
@Composable
fun MusicPlayButtons(tracks: List<WavlakeTrack>, extra: @Composable () -> Unit) {
    val enabled = tracks.isNotEmpty()
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.alpha(if (enabled) 1f else 0.5f)) {
        MusicPillButton("Play", Icons.Filled.PlayArrow, filled = true, enabled = enabled) { MusicPlayer.play(tracks) }
        MusicPillButton("Shuffle", Icons.Filled.Shuffle, filled = false, enabled = enabled) { MusicPlayer.playShuffled(tracks) }
        extra()
    }
}

@Composable
fun MusicPillButton(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .heightIn(min = 36.dp)
            .clip(CircleShape)
            .background(if (filled) accent else accent.copy(alpha = 0.14f))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
    ) {
        Icon(icon, contentDescription = null, tint = if (filled) Color.White else accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, color = if (filled) Color.White else accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun CollectionTile(
    title: String,
    subtitle: String,
    art: String?,
    shape: Shape,
    size: androidx.compose.ui.unit.Dp = 110.dp,
    onClick: () -> Unit,
) {
    Column(Modifier.width(size).clickable(onClick = onClick)) {
        Artwork(art, size, shape)
        Text(title, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(subtitle, color = SecondaryText, fontSize = 11.sp)
    }
}

@Composable
fun Artwork(url: String?, size: androidx.compose.ui.unit.Dp, shape: Shape = RoundedCornerShape(8.dp)) {
    Box(Modifier.size(size).clip(shape).background(Color.White.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.MusicNote, contentDescription = null, tint = SecondaryText)
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MusicTrackRow(
    track: WavlakeTrack,
    isCurrent: Boolean,
    isPlaying: Boolean,
    actions: MusicActions,
    /** Album order: the track number shows instead of the cover. */
    number: Int? = null,
    onTap: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(role = Role.Button, onClick = onTap, onLongClick = { menu = true })
                .padding(vertical = 6.dp)
                .semantics { contentDescription = "${track.title}, ${track.artist}" },
        ) {
            if (number != null) Box(Modifier.size(width = 28.dp, height = 40.dp), contentAlignment = Alignment.Center) {
                if (isCurrent) {
                    Icon(
                        if (isPlaying) Icons.Filled.GraphicEq else Icons.Filled.PlayArrow,
                        contentDescription = null, tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(18.dp),
                    )
                } else {
                    Text("$number", color = SecondaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            } else Box(contentAlignment = Alignment.Center) {
                Artwork(track.albumArtUrl, 48.dp)
                if (isCurrent) {
                    Box(Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = 0.45f)))
                    Icon(
                        if (isPlaying) Icons.Filled.GraphicEq else Icons.Filled.PlayArrow,
                        contentDescription = null, tint = Color.White,
                    )
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    track.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (isCurrent) LocalNostrVaultColors.current.primary else PrimaryText,
                )
                Text(track.artist, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            track.sats?.takeIf { it > 0 }?.let { sats ->
                Text("⚡ %,d".format(sats), color = Color(0xFFF7931A), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(8.dp))
            }
            track.duration?.takeIf { it > 0 }?.let { Text(formatTime(it.toLong()), color = SecondaryText, fontSize = 12.sp) }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            MusicPage.artistOf(track)?.takeIf { MusicFeedState.showingArtistId != track.artistId }?.let { page ->
                DropdownMenuItem(text = { Text("Go to ${track.artist}") }, onClick = { menu = false; MusicFeedState.reveal(page) })
            }
            MusicPage.albumOf(track)?.takeIf { MusicFeedState.showingAlbumId != track.albumId }?.let { page ->
                DropdownMenuItem(
                    text = { Text(track.albumTitle?.let { "Go to $it" } ?: "Go to album") },
                    onClick = { menu = false; MusicFeedState.reveal(page) },
                )
            }
            DropdownMenuItem(text = { Text("Share to Nostr") }, onClick = { menu = false; MusicArtistKey.share(track, actions.onShare) })
            track.artistNpub?.let(actions.npubToHex)?.let { hex ->
                DropdownMenuItem(text = { Text("${track.artist} on Nostr") }, onClick = { menu = false; actions.onOpenProfile(hex) })
            }
            DropdownMenuItem(text = { Text("Open on Wavlake") }, onClick = {
                menu = false; runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(track.pageUrl))) }
            })
        }
    }
}
