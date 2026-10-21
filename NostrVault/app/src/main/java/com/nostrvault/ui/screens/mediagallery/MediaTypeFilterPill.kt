package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nostrvault.service.*
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * The Media tab's type filter buttons. Also used by the composer's relay
 * picker, which offers only the [filters] it can attach.
 */
@Composable
internal fun MediaTypeFilterPill(
    /** The types on; see [MediaTypeSelection]. Several can be on at once. */
    selection: Set<MediaTypeFilter>,
    onSelect: (MediaTypeFilter) -> Unit,
    filters: List<MediaTypeFilter> = MediaTypeFilter.entries,
) {
    val colors = LocalNostrVaultColors.current
    GlassPill {
        for (filter in filters) {
            val (icon, label) = when (filter) {
                MediaTypeFilter.ALL -> NostrVaultIcons.GridLayout to "All"
                MediaTypeFilter.PHOTO -> NostrVaultIcons.Media to "Photos"
                MediaTypeFilter.VIDEO -> NostrVaultIcons.Video to "Videos"
                MediaTypeFilter.GIF -> NostrVaultIcons.Gif to "GIFs"
                MediaTypeFilter.OTHER -> NostrVaultIcons.Document to "Other"
            }
            MediaFilterIcon(
                icon = icon,
                label = label,
                selected = MediaTypeSelection.isOn(selection, filter),
                accentColor = colors.primary,
                onClick = { onSelect(filter) },
            )
        }
    }
}

/**
 * The type menu's icon: outline with every type on, filled once narrowed,
 * as iOS `circle.grid.2x2` / `circle.grid.2x2.fill`.
 */
internal fun mediaTypeMenuIcon(selection: Set<MediaTypeFilter>): androidx.compose.ui.graphics.vector.ImageVector =
    if (MediaTypeSelection.isAll(selection)) androidx.compose.material.icons.Icons.Outlined.GridView
    else androidx.compose.material.icons.Icons.Filled.GridView

/**
 * The type filters as one menu, for the Vault tab, where the mode pill takes
 * the leading cluster: All Media, then Photos, Videos and GIFs, ticked when
 * on. Same taps as [MediaTypeFilterPill] (iOS mediaTypeMenu).
 */
@Composable
internal fun MediaTypeMenu(
    selection: Set<MediaTypeFilter>,
    onSelect: (MediaTypeFilter) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val all = MediaTypeSelection.isAll(selection)
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }, modifier = Modifier.size(40.dp)) {
            Icon(
                imageVector = mediaTypeMenuIcon(selection),
                contentDescription = if (all) "Media type: all" else "Media type: filtered",
                tint = colors.primary,
                modifier = Modifier.size(25.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for ((filter, label, icon) in listOf(
                Triple(MediaTypeFilter.ALL, "All Media", NostrVaultIcons.GridLayout),
                Triple(MediaTypeFilter.PHOTO, "Photos", NostrVaultIcons.Media),
                Triple(MediaTypeFilter.VIDEO, "Videos", NostrVaultIcons.Video),
                Triple(MediaTypeFilter.GIF, "GIFs", NostrVaultIcons.Gif),
            )) {
                // All ticks only when everything is on; a type, only when narrowed.
                val on = if (filter == MediaTypeFilter.ALL) all else !all && filter in selection
                DropdownMenuItem(
                    text = { Text(label) },
                    leadingIcon = { Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp)) },
                    trailingIcon = if (on) {
                        { Icon(NostrVaultIcons.Check, contentDescription = "On", tint = colors.primary, modifier = Modifier.size(18.dp)) }
                    } else null,
                    // A type toggles and the menu stays open for the next; All closes it.
                    onClick = {
                        onSelect(filter)
                        if (filter == MediaTypeFilter.ALL) expanded = false
                    },
                )
            }
        }
    }
}

/** Small icon button used in the media type filter toolbar. */
@Composable
private fun MediaFilterIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    selected: Boolean,
    accentColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(40.dp)
            .semantics { this.selected = selected },
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (selected) accentColor else SecondaryText,
            modifier = Modifier.size(25.dp),
        )
    }
}
