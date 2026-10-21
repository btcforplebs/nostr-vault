package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.*

/**
 * The Media tab's toolbar buttons: type menu, sort, grid/list and upload.
 * iOS `MediaGalleryToolbar.trailingToolbarInline`.
 */
@Composable
internal fun MediaGalleryToolbarActions(
    typeSelection: Set<MediaTypeFilter>,
    onTypeTap: (MediaTypeFilter) -> Unit,
    sortOption: MediaSortOption,
    onSort: (MediaSortOption) -> Unit,
    layoutMode: MediaLayoutMode,
    onToggleLayout: () -> Unit,
    isUploading: Boolean,
    onPickPhotos: () -> Unit,
    onPickVideos: () -> Unit,
    onPickFiles: () -> Unit,
    onMagicPaste: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var showSortMenu by remember { mutableStateOf(false) }
    var showUploadMenu by remember { mutableStateOf(false) }
    MediaTypeMenu(selection = typeSelection, onSelect = onTypeTap)
    Box {
        IconButton(
            onClick = { showSortMenu = true },
            modifier = Modifier.size(40.dp),
        ) {
            Icon(
                imageVector = androidx.compose.material.icons.Icons.Filled.SwapVert,
                contentDescription = "Sort by: ${sortOption.label}",
                tint = SecondaryText,
                modifier = Modifier.size(25.dp),
            )
        }
        DropdownMenu(
            expanded = showSortMenu,
            onDismissRequest = { showSortMenu = false },
        ) {
            for (option in MediaSortOption.entries) {
                DropdownMenuItem(
                    text = { Text(option.label) },
                    // A checkmark on the active row: one choice of many.
                    leadingIcon = {
                        if (option == sortOption) {
                            Icon(
                                androidx.compose.material.icons.Icons.Filled.Check,
                                contentDescription = "Selected",
                                tint = colors.primary,
                                modifier = Modifier.size(20.dp),
                            )
                        } else {
                            Spacer(Modifier.size(20.dp))
                        }
                    },
                    onClick = {
                        showSortMenu = false
                        onSort(option)
                    },
                )
            }
        }
    }
    IconButton(
        onClick = onToggleLayout,
        modifier = Modifier.size(40.dp),
    ) {
        Icon(
            imageVector = if (layoutMode == MediaLayoutMode.GRID)
                NostrVaultIcons.CompactView else NostrVaultIcons.GridLayout,
            contentDescription = if (layoutMode == MediaLayoutMode.GRID)
                "List view" else "Grid view",
            tint = SecondaryText,
            modifier = Modifier.size(25.dp),
        )
    }
    Box {
        IconButton(
            onClick = { showUploadMenu = true },
            enabled = !isUploading,
            modifier = Modifier.size(40.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Create,
                contentDescription = "Upload",
                tint = colors.primary,
                modifier = Modifier.size(25.dp),
            )
        }
        DropdownMenu(
            expanded = showUploadMenu,
            onDismissRequest = { showUploadMenu = false },
        ) {
            DropdownMenuItem(
                text = { Text("Photos") },
                leadingIcon = { Icon(NostrVaultIcons.Media, contentDescription = null, modifier = Modifier.size(20.dp)) },
                onClick = {
                    showUploadMenu = false
                    onPickPhotos()
                },
            )
            DropdownMenuItem(
                text = { Text("Videos") },
                leadingIcon = { Icon(NostrVaultIcons.Video, contentDescription = null, modifier = Modifier.size(20.dp)) },
                onClick = {
                    showUploadMenu = false
                    onPickVideos()
                },
            )
            DropdownMenuItem(
                text = { Text("Files") },
                leadingIcon = { Icon(NostrVaultIcons.Document, contentDescription = null, modifier = Modifier.size(20.dp)) },
                onClick = {
                    showUploadMenu = false
                    onPickFiles()
                },
            )
            DropdownMenuItem(
                text = { Text("Magic Paste") },
                leadingIcon = {
                    Icon(
                        androidx.compose.material.icons.Icons.Filled.ContentPaste,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                    )
                },
                onClick = {
                    showUploadMenu = false
                    onMagicPaste()
                },
            )
        }
    }
}
