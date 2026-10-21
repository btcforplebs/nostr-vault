package com.nostrvault.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
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

/**
 * Where a list row says the file lives: null when it is on this phone (the
 * green drive icon), else the host it is linked from, or "Link only" when
 * the link has none. iOS `MediaListItem`: `item.url.host ?? "Link only"`.
 */
internal fun mediaListLocationLabel(item: BlossomMediaItem): String? {
    if (item.isLocal) return null
    return runCatching { java.net.URI(item.displayUrl).host }.getOrNull()?.takeIf { it.isNotEmpty() } ?: "Link only"
}

/** List row: thumbnail, type icon, where it lives and its backup badge. iOS `MediaListItem`. */
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

    // iOS MediaListItem: a dark card, 12 inside, 10 corners.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CardBackground.copy(alpha = 0.6f))
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            )
            .padding(12.dp),
    ) {
        // Thumbnail
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(60.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.1f)),
        ) {
            if (item.isAudio) {
                AudioThumbnail(iconSize = 20.dp)
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

        // Type icon
        Box(contentAlignment = Alignment.Center, modifier = Modifier.width(32.dp)) {
            Icon(
                imageVector = when {
                    item.isVideo -> NostrVaultIcons.Video
                    item.isAudio -> NostrVaultIcons.Waveform
                    item.isImage -> NostrVaultIcons.Media
                    else -> NostrVaultIcons.Document
                },
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(20.dp),
            )
        }

        Spacer(Modifier.width(12.dp))

        // On this phone, or the server it is linked from; then how many of
        // your Blossom servers hold it.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.weight(1f),
        ) {
            val linkedFrom = mediaListLocationLabel(item)
            if (linkedFrom == null) {
                Icon(
                    imageVector = NostrVaultIcons.Storage,
                    contentDescription = "On phone",
                    tint = SuccessGreen,
                    modifier = Modifier.size(15.dp),
                )
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f, fill = false)) {
                    Icon(NostrVaultIcons.LinkIcon, contentDescription = null, tint = InfoBlue, modifier = Modifier.size(13.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = linkedFrom,
                        color = InfoBlue,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (backup.mirrorCount > 0) {
                BlossomBackupBadge(backup = backup)
            }
        }

        // Quick backup actions, as iOS MediaListItem: upload what this phone
        // has to the servers missing it, or keep a copy of what it lacks.
        val actionTint = if (backup.busy) SecondaryText else colors.primary
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(end = 8.dp),
        ) {
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
                    tint = colors.primary,
                    modifier = Modifier.size(22.dp),
                )
            }
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
