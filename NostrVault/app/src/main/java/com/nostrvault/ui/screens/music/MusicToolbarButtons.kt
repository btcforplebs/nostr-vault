package com.nostrvault.ui.screens.music

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Whatshot
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SecondaryText

// ── Toolbar ─────────────────────────────────────────────────────

/**
 * The Music feed's toolbar controls: Trending (this week or month), an
 * artist picker of the artists you've played or opened, and Wavlake
 * artists you follow on Nostr. iOS: MusicToolbarButtons.
 */
@Composable
fun MusicToolbarButtons() {
    val musicScope by MusicFeedState.scope.collectAsState()
    val window by MusicFeedState.trendingWindow.collectAsState()
    val recent by MusicFeedState.recentArtists.collectAsState()
    val accent = LocalNostrVaultColors.current.primary
    var trendingMenu by remember { mutableStateOf(false) }
    var artistMenu by remember { mutableStateOf(false) }
    val isTrending = musicScope == MusicScope.Trending
    val artist = (musicScope as? MusicScope.Artist)?.artist
    val isFollowing = musicScope == MusicScope.Following

    Box {
        IconButton(onClick = { trendingMenu = true }, modifier = Modifier.size(40.dp)) {
            Icon(
                if (isTrending) Icons.Filled.Whatshot else Icons.Outlined.Whatshot, contentDescription = "Trending",
                tint = if (isTrending) accent else SecondaryText, modifier = Modifier.size(20.dp),
            )
        }
        DropdownMenu(expanded = trendingMenu, onDismissRequest = { trendingMenu = false }) {
            TrendingWindow.entries.forEach { w ->
                DropdownMenuItem(
                    text = { Text("Trending ${w.title.lowercase()}") },
                    leadingIcon = { Icon(if (isTrending && window == w) Icons.Filled.Check else Icons.Outlined.Whatshot, null) },
                    onClick = { trendingMenu = false; MusicFeedState.showTrending(w) },
                )
            }
        }
    }
    Box {
        IconButton(onClick = { artistMenu = true }, modifier = Modifier.size(40.dp)) {
            Icon(
                if (artist != null) Icons.Filled.AccountCircle else Icons.Outlined.AccountCircle,
                contentDescription = artist?.let { "Artist: ${it.name}" } ?: "Artists",
                tint = if (artist != null) accent else SecondaryText, modifier = Modifier.size(20.dp),
            )
        }
        DropdownMenu(expanded = artistMenu, onDismissRequest = { artistMenu = false }) {
            if (recent.isEmpty()) {
                DropdownMenuItem(text = { Text("Artists you play or open show up here") }, onClick = {}, enabled = false)
            } else {
                recent.forEach { a ->
                    DropdownMenuItem(
                        text = { Text(a.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        leadingIcon = { Icon(if (artist?.id == a.id) Icons.Filled.Check else Icons.Outlined.AccountCircle, null) },
                        onClick = { artistMenu = false; MusicFeedState.show(a) },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Clear artists", color = MaterialTheme.colorScheme.error) },
                    leadingIcon = { Icon(Icons.Filled.Delete, null, tint = MaterialTheme.colorScheme.error) },
                    onClick = { artistMenu = false; MusicFeedState.clearRecentArtists() },
                )
            }
        }
    }
    IconButton(onClick = { MusicFeedState.setScope(MusicScope.Following) }, modifier = Modifier.size(40.dp)) {
        Icon(
            if (isFollowing) Icons.Filled.People else Icons.Outlined.People, contentDescription = "Artists you follow",
            tint = if (isFollowing) accent else SecondaryText, modifier = Modifier.size(20.dp),
        )
    }
}
