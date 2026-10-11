package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.dp
import com.nostrvault.service.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * The heading of the section at the top of the grid, drawn over it once the
 * section's own heading has scrolled under the top edge; the next heading
 * pushes it up as it arrives. Compose's grid has no sticky headers before
 * foundation 1.8, hence an overlay.
 */
@Composable
internal fun PinnedGridHeader(
    state: androidx.compose.foundation.lazy.grid.LazyGridState,
    sections: List<MediaDateSection>,
    top: androidx.compose.ui.unit.Dp,
) {
    // Grid key -> its section's heading. Keys are "header:<title>" and sha256s.
    val titleByKey = remember(sections) {
        buildMap<Any, String> {
            for (section in sections) {
                if (section.title.isEmpty()) continue
                put(gridHeaderKey(section.title), section.title)
                section.items.forEach { put(it.sha256, section.title) }
            }
        }
    }
    if (titleByKey.isEmpty()) return
    var headerHeight by remember { mutableIntStateOf(0) }
    val pinned by remember(state, titleByKey) {
        derivedStateOf {
            val visible = state.layoutInfo.visibleItemsInfo
            // Offsets are measured from the content's top edge (below the padding).
            val first = visible.firstOrNull { it.offset.y + it.size.height > 0 } ?: return@derivedStateOf null
            val title = titleByKey[first.key] ?: return@derivedStateOf null
            if (first.key == gridHeaderKey(title) && first.offset.y >= 0) return@derivedStateOf null
            val next = visible.firstOrNull {
                (it.key as? String)?.startsWith(GRID_HEADER_PREFIX) == true &&
                    it.key != gridHeaderKey(title) && it.offset.y > 0
            }
            title to (next?.let { (it.offset.y - headerHeight).coerceAtMost(0) } ?: 0)
        }
    }
    pinned?.let { (title, push) ->
        Box(
            Modifier
                .padding(top = top, start = 2.dp, end = 2.dp)
                .offset { androidx.compose.ui.unit.IntOffset(0, push) }
                .onSizeChanged { headerHeight = it.height },
        ) {
            MediaSectionHeader(title)
        }
    }
}

private const val GRID_HEADER_PREFIX = "header:"
internal fun gridHeaderKey(title: String) = GRID_HEADER_PREFIX + title
