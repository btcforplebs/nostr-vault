package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import com.nostrvault.service.MediaCacheService
import com.nostrvault.ui.theme.*

/**
 * One key per viewer item: its hash, or its URL for a link-only item whose
 * hash is "". Keying by the hash alone made every link-only item share "".
 */
internal fun viewerItemKey(item: BlossomMediaItem): String = item.sha256.ifEmpty { item.displayUrl }

/** The hash each Save to Vault stored an item's bytes under, by [viewerItemKey]. */
internal class SavedVaultHashes {
    private val byItem = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun record(item: BlossomMediaItem, savedSha: String) {
        byItem[viewerItemKey(item)] = savedSha
    }

    fun savedHash(item: BlossomMediaItem): String? = byItem[viewerItemKey(item)]
}

/** Where the viewer's copy lives: on the phone, a temporary copy, or only a link. */
internal fun viewerMediaSource(inVault: Boolean, cached: Boolean): MediaCacheService.MediaSource = when {
    inVault -> MediaCacheService.MediaSource.BLOSSOM
    cached -> MediaCacheService.MediaSource.CACHED
    else -> MediaCacheService.MediaSource.REMOTE
}

/** The badge text, as iOS `MediaCacheService.MediaSource.rawValue`. */
internal fun mediaSourceLabel(source: MediaCacheService.MediaSource): String = when (source) {
    MediaCacheService.MediaSource.BLOSSOM -> "On phone"
    MediaCacheService.MediaSource.CACHED -> "Temporary copy"
    MediaCacheService.MediaSource.REMOTE -> "Link only"
}

internal fun unreachableServersText(count: Int): String =
    if (count == 1) "Couldn't reach 1 server" else "Couldn't reach $count servers"

/**
 * Source badge with Save to Vault (and Cache Locally for a bare link) when the
 * file is not on the phone. Port of iOS `SourceIndicatorView`.
 */
@Composable
internal fun MediaSourceRow(
    source: MediaCacheService.MediaSource,
    saving: Boolean,
    caching: Boolean,
    onSaveToVault: () -> Unit,
    onCacheLocally: () -> Unit,
) {
    val color = when (source) {
        MediaCacheService.MediaSource.BLOSSOM -> Color(0xFF4CAF50)
        MediaCacheService.MediaSource.CACHED -> Color(0xFF2196F3)
        MediaCacheService.MediaSource.REMOTE -> Color(0xFFFF9800)
    }
    val icon = when (source) {
        MediaCacheService.MediaSource.BLOSSOM -> NostrVaultIcons.TabVault
        MediaCacheService.MediaSource.CACHED -> NostrVaultIcons.Import
        MediaCacheService.MediaSource.REMOTE -> NostrVaultIcons.Globe
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(bottom = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .background(color.copy(alpha = 0.2f))
                .border(1.dp, color.copy(alpha = 0.3f), RoundedCornerShape(20.dp))
                .padding(horizontal = 10.dp, vertical = 6.dp),
        ) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(4.dp))
            Text(mediaSourceLabel(source), color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        if (source != MediaCacheService.MediaSource.BLOSSOM) {
            SourceActionButton("Save to Vault", busy = saving, onClick = onSaveToVault)
        }
        if (source == MediaCacheService.MediaSource.REMOTE) {
            SourceActionButton("Cache Locally", busy = caching, onClick = onCacheLocally)
        }
    }
}

@Composable
private fun SourceActionButton(label: String, busy: Boolean, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        enabled = !busy,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
        modifier = Modifier.height(30.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(14.dp), color = Color.White, strokeWidth = 2.dp)
        } else {
            Text(label, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
    }
}
