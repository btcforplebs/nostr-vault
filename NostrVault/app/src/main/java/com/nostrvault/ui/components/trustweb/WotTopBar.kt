package com.nostrvault.ui.components

import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.layout.heightIn
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BlurCircular
import com.nostrvault.ui.screens.dashboard.IconFilterButton
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.TrustMap
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlin.math.min

/** The WOT tab's layer picker icons, iOS `TrustMap.Layer.symbolName`. */
internal val TrustMap.Layer.icon: ImageVector
    get() = when (this) {
        TrustMap.Layer.EVERYONE -> NostrVaultIcons.WebOfTrust
        TrustMap.Layer.FOLLOWING -> NostrVaultIcons.People
        TrustMap.Layer.CLOSE -> NostrVaultIcons.Groups
        // iOS circle.dashed; Sparkles is the New filter's.
        TrustMap.Layer.FURTHER_OUT -> Icons.Filled.BlurCircular
    }

/** 16K, 1.5K, 912: short enough that a menu row stays on one line (iOS compactName). */
private fun compactCount(n: Int): String =
    android.icu.text.CompactDecimalFormat
        .getInstance(java.util.Locale.getDefault(), android.icu.text.CompactDecimalFormat.CompactStyle.SHORT)
        .format(n)

/**
 * The WOT tab's bar: the feed's two glass pills. Left is the layer picker,
 * built like the feed picker (icon, name, chevron; the list and the rare
 * Rebuild at the bottom after a divider). Right are search and the filter
 * icons, as on iOS.
 */
@Composable
internal fun WotTopBar(
    layer: TrustMap.Layer,
    layers: List<TrustMap.Layer>,
    counts: Map<TrustMap.Layer, Int>,
    onLayer: (TrustMap.Layer) -> Unit,
    refreshing: Boolean,
    onRebuild: () -> Unit,
    searchOpen: Boolean,
    onSearch: () -> Unit,
    onList: () -> Unit,
    filters: Set<TrustMap.Filter>,
    onFilter: (TrustMap.Filter) -> Unit,
    /** The live arrivals switches; the antenna sits after the filters. */
    liveArcs: LiveArcsState? = null,
) {
    val accent = LocalNostrVaultColors.current.primary
    var expanded by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .heightIn(min = 48.dp),
    ) {
        Box(Modifier.tutorialAnchor(TutorialContent.WOT_LAYERS)) {
            GlassPill(
                horizontalArrangement = Arrangement.Start,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClickLabel = "Pick a layer") { expanded = true }
                    .semantics { contentDescription = "Showing: ${layer.title}, ${counts[layer] ?: 0} people" },
            ) {
                Box(Modifier.size(30.dp), contentAlignment = Alignment.Center) {
                    Icon(layer.icon, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text(layer.title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                Spacer(Modifier.width(2.dp))
                Icon(NostrVaultIcons.ChevronDown, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                layers.forEach { item ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                "${item.title} · ${compactCount(counts[item] ?: 0)}",
                                fontWeight = if (item == layer) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        leadingIcon = { Icon(item.icon, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        trailingIcon = if (item == layer) {
                            { Icon(NostrVaultIcons.Check, contentDescription = "Current layer", modifier = Modifier.size(16.dp)) }
                        } else null,
                        onClick = {
                            onLayer(item)
                            expanded = false
                        },
                    )
                }
                HorizontalDivider()
                // Android's list of the layer's people. iOS has no list; it sits
                // here so the bar has room for the filters.
                DropdownMenuItem(
                    text = { Text("See as a list") },
                    leadingIcon = { Icon(NostrVaultIcons.PeopleList, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    onClick = {
                        expanded = false
                        onList()
                    },
                )
                DropdownMenuItem(
                    text = { Text(if (refreshing) "Rebuilding…" else "Rebuild your web") },
                    leadingIcon = { Icon(NostrVaultIcons.Refresh, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    enabled = !refreshing,
                    onClick = {
                        expanded = false
                        onRebuild()
                    },
                )
            }
        }
        Spacer(Modifier.weight(1f))
        GlassPill(horizontalArrangement = Arrangement.Start) {
            IconButton(onClick = onSearch, modifier = Modifier.size(40.dp).tutorialAnchor(TutorialContent.WOT_SEARCH)) {
                Icon(NostrVaultIcons.Search, contentDescription = "Find someone",
                    tint = if (searchOpen) accent else SecondaryText, modifier = Modifier.size(22.dp))
            }
            Box(
                Modifier
                    .padding(horizontal = 4.dp)
                    .width(1.dp)
                    .height(20.dp)
                    .background(Color.White.copy(alpha = 0.15f)),
            )
            TrustMap.Filter.entries.forEach { filter ->
                IconFilterButton(
                    icon = filter.icon,
                    contentDescription = filter.title,
                    isSelected = filter in filters,
                    onClick = { onFilter(filter) },
                )
            }
            if (liveArcs != null) LiveArcsToggle(liveArcs)
        }
    }
}
