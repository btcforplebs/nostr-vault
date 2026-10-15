package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.TrustMap

@Composable
internal fun TrustWebViewWOTTabBar(
    layer: TrustMap.Layer,
    vouches: Map<String, Int>?,
    counts: Map<TrustMap.Layer, Int>,
    onLayer: (TrustMap.Layer) -> Unit,
    refreshState: RefreshState?,
    onRebuild: () -> Unit,
    searchOpen: Boolean,
    onSearch: () -> Unit,
    onList: () -> Unit,
    search: @Composable ColumnScope.() -> Unit,
    crumbs: List<String>,
    crumbRow: @Composable (Modifier) -> Unit,
    liveRebuild: Boolean,
    mappingWeb: Boolean,
    filters: Set<TrustMap.Filter>,
    onFilter: (TrustMap.Filter) -> Unit,
    filterNote: FilterNoteState,
    liveArcs: LiveArcsState? = null,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)),
    ) {
        WotTopBar(
            layer = layer,
            layers = TrustMap.layers(vouches != null),
            counts = counts,
            onLayer = onLayer,
            refreshing = refreshState != null,
            onRebuild = onRebuild,
            searchOpen = searchOpen,
            onSearch = onSearch,
            onList = onList,
            filters = filters,
            onFilter = onFilter,
            liveArcs = liveArcs,
        )
        if (searchOpen) {
            search()
        }
        if (crumbs.size > 1) crumbRow(Modifier.fillMaxWidth())
        WotLivePill(
            caption = when {
                // The Rebuild button's steps, then how it ended (iOS).
                refreshState != null -> refreshState?.caption
                liveRebuild -> "Rebuilding your web"
                mappingWeb -> "Mapping your web"
                else -> null
            },
            outcome = refreshState?.takeIf { it.done }?.let { if (it.failed) WotPillOutcome.Failed else WotPillOutcome.Saved },
        )
    }
}
