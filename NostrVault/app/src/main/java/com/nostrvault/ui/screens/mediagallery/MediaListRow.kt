package com.nostrvault.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.service.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** List row with thumbnail and metadata. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun MediaListRow(
    item: BlossomMediaItem,
    backup: BackupBadgeState,
    /** This file's long-press menu is open (held by sha, not position). */
    menuOpen: Boolean,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
    shareLink: String,
    onSaveToPhotos: () -> Unit,
    onDelete: (DeleteScope) -> Unit,
    moderationTarget: String?,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
    sizeLookup: BlobSizeLookup? = null,
) {
    val context = LocalContext.current
    // Z1: a size no list, note or file gave is asked of the server once the row shows.
    var learnedSize by remember(item.sha256) { mutableStateOf<Long?>(null) }
    if (sizeLookup != null && (item.size ?: 0L) <= 0L) {
        LaunchedEffect(item.sha256, item.displayUrl) {
            learnedSize = withContext(Dispatchers.IO) { sizeLookup.cached(item.sha256) }
                ?: sizeLookup.size(item.sha256, item.displayUrl)
        }
    }
    val colors = LocalNostrVaultColors.current

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            )
            .padding(4.dp),
    ) {
        // Thumbnail
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(60.dp)
                .clip(RoundedCornerShape(6.dp)),
        ) {
            if (item.isAudio) {
                AudioThumbnail(iconSize = 24.dp)
            } else {
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(com.nostrvault.service.VaultVideoFrameFetcher.tileData(item.sha256, item.isVideo, item.localFile, item.displayUrl))
                        .size(160, 160)
                        .crossfade(false) // Instant rendering for list thumbnails
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            if (item.isVideo) {
                Icon(
                    imageVector = NostrVaultIcons.PlayCircle,
                    contentDescription = "Video",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(20.dp),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        // Metadata
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.sha256.take(12) + "...",
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            // "2.4 MB · Video · 3 Nov", as iOS MediaRowDetailLine; "—" for an unknown size.
            Text(
                text = MediaRowLine.text(item.size?.takeIf { it > 0 } ?: learnedSize, MediaRowLine.typeLabel(item), item.sortTime),
                color = SecondaryText,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // Where it is: this phone's vault, or the link's host (iOS MediaListItem's location line).
            Text(
                text = if (item.isLocal) "On this device" else MediaRowLine.host(item.displayUrl) ?: "Link only",
                color = if (item.isLocal) Color(0xFF34C759) else TertiaryText,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Quick backup actions, as iOS MediaListItem: upload what this phone
        // has to the servers missing it, or keep a copy of what it lacks.
        val actionTint = if (backup.busy) SecondaryText else colors.primary
        if (item.isLocal && backup.summary?.needsMirror == true) {
            IconButton(onClick = backup.onMirror, enabled = !backup.busy, modifier = Modifier.size(36.dp)) {
                Icon(
                    imageVector = if (backup.busy) NostrVaultIcons.ArrowUpCircleFill
                    else NostrVaultIcons.ArrowUpCircle,
                    contentDescription = if (backup.busy) "Copying" else "Copy to your media servers",
                    tint = actionTint,
                    modifier = Modifier.size(22.dp),
                )
            }
        } else if (!item.isLocal) {
            IconButton(onClick = backup.onSaveToVault, enabled = !backup.busy, modifier = Modifier.size(36.dp)) {
                Icon(
                    imageVector = if (backup.busy) NostrVaultIcons.ArrowDownCircleFill
                    else NostrVaultIcons.ArrowDownCircle,
                    contentDescription = if (backup.busy) "Saving" else "Save to Vault",
                    tint = actionTint,
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        // Quick copy action
        IconButton(
            onClick = { clipboardManager.setText(AnnotatedString(shareLink)) },
            modifier = Modifier.size(36.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Copy,
                contentDescription = "Copy link",
                tint = SecondaryText,
                modifier = Modifier.size(18.dp),
            )
        }

        // Context menu
        MediaItemContextMenu(
            expanded = menuOpen,
            item = item,
            backup = backup,
            noteId = noteId,
            onNoteClick = onNoteClick,
            onDismiss = onDismissMenu,
            mediaCacheService = mediaCacheService,
            clipboardManager = clipboardManager,
            shareLink = shareLink,
            onSaveToPhotos = onSaveToPhotos,
            onDelete = onDelete,
            moderationTarget = moderationTarget,
            onReport = onReport,
            onBlock = onBlock,
        )
    }
}
