package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.nostrvault.service.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** Shared context menu for grid and list items. */
@Composable
internal fun MediaItemContextMenu(
    expanded: Boolean,
    item: BlossomMediaItem,
    backup: BackupBadgeState,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onDismiss: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
    shareLink: String,
    onSaveToPhotos: () -> Unit,
    onDelete: (DeleteScope) -> Unit,
    /** Someone else's media: offer Report Media and Block User on them. */
    moderationTarget: String?,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
) {
    val is404 = remember(item.displayUrl) { mediaCacheService.isKnown404(item.displayUrl) }
    // iOS groups the two deletes under a "Delete" submenu; tapping it swaps
    // the menu for them. Closed again whenever the menu closes.
    var deleteOpen by remember { mutableStateOf(false) }
    LaunchedEffect(expanded) { if (!expanded) deleteOpen = false }

    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
    ) {
        if (deleteOpen) {
            MediaDeleteSubmenu(onDismiss = onDismiss, onDelete = onDelete)
            return@DropdownMenu
        }
        // Only offered when a loaded note actually references this blob. An
        // always-present item that does nothing for most files would be the same
        // dead affordance in a different shape.
        if (noteId != null) {
            DropdownMenuItem(
                text = { Text("Open Note") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Articles, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onNoteClick(noteId)
                },
            )
        }
        DropdownMenuItem(
            text = { Text("Copy Link") },
            leadingIcon = {
                Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            onClick = {
                clipboardManager.setText(AnnotatedString(shareLink))
                onDismiss()
            },
        )
        if (item.isImage || item.isVideo) {
            DropdownMenuItem(
                text = { Text("Save to Photos") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Import, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onSaveToPhotos()
                },
            )
        }
        if (!item.isLocal) {
            DropdownMenuItem(
                text = { Text(if (backup.busy) "Saving…" else "Save to Vault") },
                enabled = !backup.busy,
                leadingIcon = {
                    Icon(NostrVaultIcons.Storage, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    backup.onSaveToVault()
                },
            )
        } else if (backup.summary?.needsMirror == true) {
            // On the phone, and some Blossom server does not have it yet.
            DropdownMenuItem(
                text = { Text(if (backup.busy) "Mirroring…" else "Mirror to Blossom") },
                enabled = !backup.busy,
                leadingIcon = {
                    Icon(NostrVaultIcons.ArrowUp, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    backup.onMirror()
                },
            )
        }
        // Order as iOS: saving and mirroring, then Delete (each delete asks
        // for confirmation first, as in the viewer), then Mark as 404.
        DropdownMenuItem(
            text = { Text("Delete") },
            leadingIcon = {
                Icon(androidx.compose.material.icons.Icons.Outlined.Delete, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            trailingIcon = {
                Icon(NostrVaultIcons.Navigate, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            onClick = { deleteOpen = true },
        )
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text(if (is404) "Remove from 404" else "Mark as 404") },
            leadingIcon = {
                Icon(NostrVaultIcons.Alert, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            onClick = {
                if (is404) {
                    mediaCacheService.unmarkNotFound(item.displayUrl)
                } else {
                    mediaCacheService.markNotFound(item.displayUrl)
                }
                onDismiss()
            },
        )
        // Last, as on iOS: only for media someone else posted. Not red: iOS
        // gives neither a destructive role.
        if (moderationTarget != null) {
            DropdownMenuItem(
                text = { Text("Report Media") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Flag, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onReport(moderationTarget)
                },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Block User") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Blocked, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onBlock(moderationTarget)
                },
            )
        }
    }
}

/** iOS's "Delete" submenu: both deletes, red, each confirmed by the caller. */
@Composable
private fun MediaDeleteSubmenu(onDismiss: () -> Unit, onDelete: (DeleteScope) -> Unit) {
    DropdownMenuItem(
        text = { Text("Delete from mirrors", color = ErrorRed) },
        leadingIcon = {
            Icon(androidx.compose.material.icons.Icons.Outlined.Delete, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp))
        },
        onClick = {
            onDismiss()
            onDelete(DeleteScope.MIRRORS)
        },
    )
    DropdownMenuItem(
        text = { Text("Delete everywhere", color = ErrorRed) },
        leadingIcon = {
            Icon(NostrVaultIcons.Delete, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp))
        },
        onClick = {
            onDismiss()
            onDelete(DeleteScope.EVERYWHERE)
        },
    )
}
