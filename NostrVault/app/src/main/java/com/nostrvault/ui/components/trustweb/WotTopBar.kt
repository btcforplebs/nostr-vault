package com.nostrvault.ui.components

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
import androidx.compose.material.icons.filled.Looks3
import androidx.compose.material.icons.filled.Looks4
import androidx.compose.material.icons.filled.Looks5
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
        // iOS 3.circle, 4.circle, 5.circle.
        TrustMap.Layer.HOP3 -> Icons.Filled.Looks3
        TrustMap.Layer.HOP4 -> Icons.Filled.Looks4
        TrustMap.Layer.HOP5 -> Icons.Filled.Looks5
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
    /** Hops greyed out until a desktop Vault ranks them. */
    lockedHops: Set<TrustMap.Layer>,
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
                // iOS: 7 leading and 7 vertical around a 30 box (the pill
                // gives 6 and 4), a 15 icon, 8 to the name, 3 to a 9pt chevron
                // and 12 trailing (the pill gives 6).
                Box(Modifier.padding(start = 1.dp, top = 3.dp, bottom = 3.dp).size(30.dp), contentAlignment = Alignment.Center) {
                    Icon(layer.icon, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(15.dp))
                }
                Spacer(Modifier.width(8.dp))
                Text(layer.title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                // The arrow's glyph fills half its 14 box: 3.5 either side
                // stands in for the 3 gap, and leaves 2.5 of the 6 trailing.
                Icon(NostrVaultIcons.ChevronDown, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(2.5.dp))
            }
            // The dock hold menu's look, as the feed list (WotLayerMenu).
            WotLayerMenu(
                expanded = expanded,
                onDismiss = { expanded = false },
                layers = layers,
                current = layer,
                counts = layers.filter { it !in lockedHops && (it.hop == null || it in counts) }
                    .associateWith { compactCount(counts[it] ?: 0) },
                locked = lockedHops,
                onPick = onLayer,
                onList = onList,
                refreshing = refreshing,
                onRebuild = onRebuild,
            )
        }
        Spacer(Modifier.weight(1f))
        GlassPill(horizontalArrangement = Arrangement.Start) {
            IconButton(onClick = onSearch, modifier = Modifier.size(40.dp).tutorialAnchor(TutorialContent.WOT_SEARCH)) {
                Icon(NostrVaultIcons.Search, contentDescription = "Find someone",
                    tint = if (searchOpen) accent else SecondaryText, modifier = Modifier.size(22.dp))
            }
            PillDivider()
            TrustMap.Filter.entries.forEach { filter ->
                IconFilterButton(
                    icon = filter.icon,
                    contentDescription = filter.title,
                    isSelected = filter in filters,
                    onClick = { onFilter(filter) },
                )
            }
            // iOS: search | filters | antenna.
            if (liveArcs != null) {
                PillDivider()
                LiveArcsToggle(liveArcs)
            }
        }
    }
}

/** The thin line between the right pill's groups (iOS `Divider().frame(height: 20)`). */
@Composable
private fun PillDivider() {
    Box(
        Modifier
            .padding(horizontal = 4.dp)
            .width(1.dp)
            .height(20.dp)
            .background(Color.White.copy(alpha = 0.15f)),
    )
}
