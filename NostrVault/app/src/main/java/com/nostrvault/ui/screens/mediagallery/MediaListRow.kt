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
    index: Int,
    backup: BackupBadgeState,
    contextMenuTarget: Int?,
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
) {
    val context = LocalContext.current
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
                        .data(item.localFile ?: item.displayUrl)
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Type badge
                Text(
                    text = when {
                        item.isVideo -> "Video"
                        item.isImage -> "Image"
                        item.isAudio -> "Audio"
                        else -> "Other"
                    },
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
                if (item.size != null && item.size > 0) {
                    Text(
                        text = " \u00B7 ${formatFileSize(item.size)}",
                        color = TertiaryText,
                        fontSize = 12.sp,
                    )
                }
                if (item.isLocal) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        imageVector = NostrVaultIcons.Blossom,
                        contentDescription = "Local",
                        tint = Color(0xFF4CAF50),
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }

        // Quick backup actions, as iOS MediaListItem: upload what this phone
        // has to the servers missing it, or keep a copy of what it lacks.
        val actionTint = if (backup.busy) SecondaryText else colors.primary
        if (item.isLocal && backup.summary?.needsMirror == true) {
            IconButton(onClick = backup.onMirror, enabled = !backup.busy, modifier = Modifier.size(36.dp)) {
                Icon(
                    imageVector = if (backup.busy) NostrVaultIcons.ArrowUpCircleFill
                    else NostrVaultIcons.ArrowUpCircle,
                    contentDescription = if (backup.busy) "Mirroring" else "Mirror to Blossom",
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
            expanded = contextMenuTarget == index,
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

private fun formatFileSize(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
    }
}
