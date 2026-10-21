package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.components.FilterNote
import com.nostrvault.ui.components.rememberFilterNoteState
import com.nostrvault.ui.theme.*

/** The sort menu row's icon, as iOS `MediaSortOption.icon`. */
private val MediaSortOption.icon: ImageVector
    get() = when (this) {
        MediaSortOption.NEWEST_FIRST -> Icons.Filled.ArrowDownward // arrow.down
        MediaSortOption.OLDEST_FIRST -> Icons.Filled.ArrowUpward // arrow.up
        MediaSortOption.MEDIA_TYPE -> Icons.Filled.Apps // square.grid.3x3
        MediaSortOption.ON_RELAY_FIRST -> Icons.Filled.Storage // externaldrive
    }

/** iOS `toggleMediaLayout`'s note: "Layout · grid" / "Layout · list". */
internal fun mediaLayoutNoteSetting(mode: MediaLayoutMode): String =
    if (mode == MediaLayoutMode.GRID) "grid" else "list"

/**
 * The Media tab's toolbar buttons: type menu, sort, grid/list and upload,
 * all in the accent colour, each tap leaving a filter note under the
 * toolbar. iOS `MediaGalleryToolbar.trailingToolbarInline`.
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
    val filterNote = rememberFilterNoteState()
    var showSortMenu by remember { mutableStateOf(false) }
    var showUploadSheet by remember { mutableStateOf(false) }
    MediaTypeMenu(
        selection = typeSelection,
        onSelect = { filter ->
            onTypeTap(filter)
            val after = MediaTypeSelection.tap(typeSelection, filter)
            filterNote.show(
                FilterNote.setting(mediaTypeMenuIcon(after), "Media type", MediaTypeSelection.noteSetting(after)),
            )
        },
    )
    Box {
        IconButton(
            onClick = { showSortMenu = true },
            modifier = Modifier.size(40.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.SwapVert,
                contentDescription = "Sort by: ${sortOption.label}",
                tint = colors.primary,
                modifier = Modifier.size(25.dp),
            )
        }
        DropdownMenu(
            expanded = showSortMenu,
            onDismissRequest = { showSortMenu = false },
        ) {
            for (option in MediaSortOption.entries) {
                val selected = option == sortOption
                DropdownMenuItem(
                    text = { Text(option.label) },
                    // A checkmark in place of the active row's icon: one choice of many.
                    leadingIcon = {
                        Icon(
                            imageVector = if (selected) Icons.Filled.Check else option.icon,
                            contentDescription = if (selected) "Selected" else null,
                            modifier = Modifier.size(20.dp),
                        )
                    },
                    onClick = {
                        showSortMenu = false
                        onSort(option)
                        filterNote.show(FilterNote.setting(Icons.Filled.SwapVert, "Sort", option.label.lowercase()))
                    },
                )
            }
        }
    }
    IconButton(
        onClick = {
            onToggleLayout()
            val after = if (layoutMode == MediaLayoutMode.GRID) MediaLayoutMode.LIST else MediaLayoutMode.GRID
            filterNote.show(
                FilterNote.setting(
                    if (after == MediaLayoutMode.GRID) NostrVaultIcons.GridLayout else NostrVaultIcons.ListLayout,
                    "Layout",
                    mediaLayoutNoteSetting(after),
                ),
            )
        },
        modifier = Modifier.size(40.dp),
    ) {
        Icon(
            imageVector = if (layoutMode == MediaLayoutMode.GRID)
                NostrVaultIcons.CompactView else NostrVaultIcons.GridLayout,
            contentDescription = if (layoutMode == MediaLayoutMode.GRID)
                "List View" else "Grid View",
            tint = colors.primary,
            modifier = Modifier.size(25.dp),
        )
    }
    IconButton(
        onClick = { showUploadSheet = true },
        enabled = !isUploading,
        modifier = Modifier.size(40.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Create,
            contentDescription = "Upload Options",
            tint = colors.primary,
            modifier = Modifier.size(25.dp),
        )
    }
    if (showUploadSheet) {
        MediaUploadSheet(
            onDismiss = { showUploadSheet = false },
            onPickPhotos = onPickPhotos,
            onPickVideos = onPickVideos,
            onPickFiles = onPickFiles,
            onMagicPaste = onMagicPaste,
        )
    }
}
