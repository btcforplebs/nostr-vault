package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.nostrvault.fips.meshAuthor
import com.nostrvault.ui.theme.*

/**
 * A profile Media tile's picture, tagged with [author] so a mesh-only blob is
 * read from their vault, as the feed does (#1011).
 */
internal fun profileTileImageModel(context: android.content.Context, url: String, author: String): coil.request.ImageRequest =
    coil.request.ImageRequest.Builder(context)
        .data(url)
        .meshAuthor(author)
        .apply {
            // iOS grid tiles hold a GIF still (`shouldAnimate: false`); a grid of
            // looping GIFs is noise. The first frame comes from the plain decoder.
            if (isGifUrl(url)) {
                decoderFactory(coil.decode.BitmapFactoryDecoder.Factory())
                // Its own cache entry: under the plain URL this still frame
                // would stand in for the animated GIF in notes and the viewer.
                memoryCacheKey("$url#still")
            }
        }
        .build()

/**
 * One Media grid tile. Audio has no picture, so it gets iOS's dark tile with
 * a waveform. A Blossom file carries the backup badge bottom-right, as iOS.
 * Long-press opens iOS `MediaGridItem`'s menu: the same on your own profile,
 * plus Report Media / Block User on someone else's.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun ProfileMediaTile(
    url: String,
    author: String,
    viewModel: ProfileViewModel,
    onOpen: () -> Unit,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
    /** Asks to delete this tile's blob (by hash); only offered on your own Blossom files. */
    onDelete: (String, com.nostrvault.ui.screens.DeleteScope) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val clipboard = LocalClipboardManager.current
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    val isAudio = remember(url) { com.nostrvault.ui.components.isAudioUrl(url) }
    val isVideo = remember(url) { com.nostrvault.ui.components.isVideoUrl(url) }
    val context = androidx.compose.ui.platform.LocalContext.current
    // Keyed by url: rows are by position, so new posts can shift a tile under an open menu.
    var menuOpen by remember(url) { mutableStateOf(false) }
    val busyUrl by viewModel.mediaBusyUrl.collectAsState()
    val presence by viewModel.mirrorPresence.collectAsState()
    // Ask the servers when the menu opens, so Mirror to Blossom can appear.
    LaunchedEffect(menuOpen) { if (menuOpen) viewModel.checkMediaBackup(url) }

    val tileModifier = Modifier
        .fillMaxSize()
        .clip(RoundedCornerShape(8.dp))
        .background(if (isAudio) AudioTileBg else SecondaryGroupedBg)
        .combinedClickable(
            onClick = onOpen,
            onLongClick = {
                haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                menuOpen = true
            },
            onLongClickLabel = "Media options",
        )
    if (isAudio) {
        Box(contentAlignment = Alignment.Center, modifier = tileModifier.semantics { contentDescription = "Audio" }) {
            Icon(NostrVaultIcons.Waveform, contentDescription = null, tint = colors.primary, modifier = Modifier.size(36.dp))
            ProfileTileBackupBadge(url, Modifier.align(Alignment.BottomEnd))
        }
    } else {
        val model = remember(url, author) { profileTileImageModel(context, url, author) }
        Box(contentAlignment = Alignment.Center, modifier = tileModifier) {
            AsyncImage(model = model, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
            if (isVideo) {
                // iOS VideoThumbnailView: a 40pt play.circle.fill over the frame.
                Icon(
                    NostrVaultIcons.PlayCircle,
                    contentDescription = "Video",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(40.dp),
                )
            }
            ProfileTileBackupBadge(url, Modifier.align(Alignment.BottomEnd))
        }
    }

    if (menuOpen) {
        val busy = busyUrl == url
        val actions = viewModel.mediaMenu(url, author, presence)
        var deleteOpen by remember { mutableStateOf(false) }
        DropdownMenu(expanded = true, onDismissRequest = { menuOpen = false }) {
            fun close() { menuOpen = false }
            val deletes = actions.filter { it == ProfileMediaAction.DELETE_FROM_MIRRORS || it == ProfileMediaAction.DELETE_EVERYWHERE }
            actions.forEach { action ->
                when (action) {
                    ProfileMediaAction.COPY_LINK -> DropdownMenuItem(
                        text = { Text("Copy Link") },
                        leadingIcon = { Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(20.dp)) },
                        onClick = { clipboard.setText(AnnotatedString(url)); close() },
                    )
                    ProfileMediaAction.SAVE_TO_PHOTOS -> DropdownMenuItem(
                        text = { Text("Save to Photos") },
                        leadingIcon = { Icon(NostrVaultIcons.Import, contentDescription = null, modifier = Modifier.size(20.dp)) },
                        onClick = { close(); viewModel.saveMediaToPhotos(url) },
                    )
                    ProfileMediaAction.SAVE_TO_VAULT -> DropdownMenuItem(
                        text = { Text(if (busy) "Saving…" else "Save to Vault") },
                        enabled = !busy,
                        leadingIcon = { Icon(NostrVaultIcons.Storage, contentDescription = null, modifier = Modifier.size(20.dp)) },
                        onClick = { close(); viewModel.saveMediaToVault(url) },
                    )
                    ProfileMediaAction.MIRROR_TO_BLOSSOM -> DropdownMenuItem(
                        text = { Text(if (busy) "Mirroring…" else "Mirror to Blossom") },
                        enabled = !busy,
                        leadingIcon = { Icon(NostrVaultIcons.ArrowUp, contentDescription = null, modifier = Modifier.size(20.dp)) },
                        onClick = { close(); viewModel.mirrorMediaToBlossom(url) },
                    )
                    // iOS: one "Delete" item holding both choices; each asks first.
                    ProfileMediaAction.DELETE_FROM_MIRRORS, ProfileMediaAction.DELETE_EVERYWHERE -> {
                        if (action == deletes.first()) {
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = { Text("Delete") },
                                leadingIcon = { Icon(NostrVaultIcons.Delete, contentDescription = null, modifier = Modifier.size(20.dp)) },
                                trailingIcon = { Icon(if (deleteOpen) NostrVaultIcons.ChevronDown else NostrVaultIcons.Navigate, contentDescription = null, modifier = Modifier.size(18.dp)) },
                                onClick = { deleteOpen = !deleteOpen },
                            )
                        }
                        if (deleteOpen) {
                            val mirrors = action == ProfileMediaAction.DELETE_FROM_MIRRORS
                            DropdownMenuItem(
                                text = { Text(if (mirrors) "Delete from mirrors" else "Delete everywhere", color = ErrorRed) },
                                leadingIcon = { Icon(NostrVaultIcons.Delete, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp)) },
                                contentPadding = PaddingValues(start = 28.dp, end = 12.dp),
                                onClick = {
                                    close()
                                    val scope = if (mirrors) com.nostrvault.ui.screens.DeleteScope.MIRRORS else com.nostrvault.ui.screens.DeleteScope.EVERYWHERE
                                    blossomHashOf(url)?.let { onDelete(it, scope) }
                                },
                            )
                        }
                    }
                    ProfileMediaAction.MARK_404, ProfileMediaAction.UNMARK_404 -> {
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text(if (action == ProfileMediaAction.UNMARK_404) "Remove from 404" else "Mark as 404") },
                            leadingIcon = { Icon(NostrVaultIcons.Alert, contentDescription = null, modifier = Modifier.size(20.dp)) },
                            onClick = { viewModel.toggleMedia404(url); close() },
                        )
                    }
                    ProfileMediaAction.REPORT -> DropdownMenuItem(
                        text = { Text("Report Media", color = ErrorRed) },
                        leadingIcon = { Icon(NostrVaultIcons.Flag, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp)) },
                        onClick = { close(); viewModel.mediaModerationTarget(author)?.let(onReport) },
                    )
                    ProfileMediaAction.BLOCK -> {
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("Block User", color = ErrorRed) },
                            leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp)) },
                            onClick = { close(); viewModel.mediaModerationTarget(author)?.let(onBlock) },
                        )
                    }
                }
            }
        }
    }
}

/** iOS MediaGridItem's audio tile: Color(red: 0.1, green: 0.1, blue: 0.14). */
private val AudioTileBg = Color(0xFF1A1A24)

/** A `.gif` link, query and fragment aside. */
internal fun isGifUrl(url: String): Boolean =
    url.substringBefore('#').substringBefore('?').endsWith(".gif", ignoreCase = true)
