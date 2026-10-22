package com.nostrvault.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.fips.FipsMediaRouter
import com.nostrvault.fips.meshAuthor
import com.nostrvault.service.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** iOS's audio tile: no picture, so a waveform on Color(red: 0.1, green: 0.1, blue: 0.14). */
@Composable
internal fun AudioThumbnail(iconSize: androidx.compose.ui.unit.Dp) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF1A1A24))
            .semantics { contentDescription = "Audio" },
    ) {
        Icon(
            imageVector = NostrVaultIcons.Waveform,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(iconSize),
        )
    }
}

/** Heading over one dated run of media (iOS `mediaSectionHeader`). */
@Composable
internal fun MediaSectionHeader(title: String) {
    Text(
        text = title,
        color = PrimaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.3.sp,
        modifier = Modifier
            .fillMaxWidth()
            .background(WindowBackground.copy(alpha = 0.92f))
            .padding(horizontal = 6.dp, vertical = 8.dp),
    )
}

/**
 * Who a Vault tile's image may be read from over the mesh: the author of the
 * note that posted it when that is someone else ([moderationTarget]), else the
 * owner, whose vault this gallery lists. Feed parity (#1011).
 */
internal fun vaultTileMeshAuthor(moderationTarget: String?, ownerHex: String): String? =
    moderationTarget ?: ownerHex.takeIf { it.isNotEmpty() }

internal fun vaultGridImageRequest(
    context: android.content.Context,
    item: BlossomMediaItem,
    moderationTarget: String?,
    ownerHex: String,
): ImageRequest = ImageRequest.Builder(context)
    .data(item.localFile ?: item.displayUrl)
    .meshAuthor(vaultTileMeshAuthor(moderationTarget, ownerHex))
    .size(360, 360)
    .crossfade(false) // Instant rendering for grid thumbnails
    .build()

/** Grid cell with context menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun MediaGridCell(
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

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(2.dp))
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            ),
    ) {
        if (item.isAudio) {
            AudioThumbnail(iconSize = 36.dp)
        } else {
            AsyncImage(
                model = vaultGridImageRequest(context, item, moderationTarget, FipsMediaRouter.ownerHex()),
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
                modifier = Modifier.size(32.dp),
            )
        }

        // Source indicator dot (green = local blossom)
        if (item.isLocal) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(4.dp)
                    .size(8.dp)
                    .clip(CircleShape)
                    .then(Modifier.background(Color(0xFF4CAF50))),
            )
        }

        // How many of your Blossom servers hold it, so you can spot what is
        // not backed up without opening it.
        if (backup.mirrorCount > 0) {
            BlossomBackupBadge(
                backup = backup,
                compact = true,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(4.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 5.dp, vertical = 2.dp),
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
