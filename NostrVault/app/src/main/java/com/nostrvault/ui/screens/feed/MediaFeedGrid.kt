package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.first
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.ui.components.FullScreenMediaRouter
import com.nostrvault.ui.components.MediaSourceKey
import com.nostrvault.ui.components.MediaZoomSources
import com.nostrvault.ui.components.mediaZoomSource
import com.nostrvault.ui.components.RetryableAsyncImage
import com.nostrvault.ui.components.isVideoUrl
import com.nostrvault.ui.theme.*

@Composable
internal fun MediaFeedGrid(
    notes: List<FeedNote>,
    /** Which side of Following / Global came back empty, for the empty text. */
    scopeFollowing: Boolean,
    isRefreshing: Boolean,
    isLoadingMore: Boolean,
    contentPadding: PaddingValues,
    onNoteClick: (String) -> Unit,
    onLoadMore: () -> Unit,
) {
    if (notes.isEmpty()) {
        if (!isRefreshing) ScopedEmptyPlaceholder(FeedMode.MEDIA, scopeFollowing, onRefresh = {}, onShowGlobal = {})
        return
    }

    val gridState = rememberLazyGridState()

    // The pager opens across the first media of every cell, so its indices line up
    // 1:1 with the grid. filterMediaNotes guarantees a non-empty mediaURLs per note.
    val gridUrls = remember(notes) { notes.map { it.mediaURLs.first() } }
    val zoomOrigin = remember { MediaZoomSources.newOrigin() }

    // Infinite scroll: load older media as the user nears the end of the grid.
    val shouldLoadMore by remember {
        derivedStateOf {
            val last = gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= gridState.layoutInfo.totalItemsCount - 6
        }
    }
    LoadMoreEffect(shouldLoadMore, isLoadingMore, notes.size, onLoadMore)

    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        state = gridState,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        contentPadding = PaddingValues(
            top = contentPadding.calculateTopPadding(),
            bottom = contentPadding.calculateBottomPadding() + 88.dp,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(
            count = notes.size,
            key = { notes[it].id },
        ) { index ->
            val note = notes[index]
            MediaGridCell(
                url = note.mediaURLs.first(),
                mediaCount = note.mediaURLs.size,
                sourceKey = MediaSourceKey(zoomOrigin, index),
                onTap = { FullScreenMediaRouter.open(gridUrls, index, zoomOrigin) },
                onLongPress = { onNoteClick(note.id) },
            )
        }

        if (isLoadingMore) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                ) {
                    CircularProgressIndicator(
                        color = LocalNostrVaultColors.current.primary,
                        modifier = Modifier.size(24.dp),
                    )
                }
            }
        }
    }

}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MediaGridCell(
    url: String,
    mediaCount: Int,
    sourceKey: MediaSourceKey,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .mediaZoomSource(sourceKey, crop = true)
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            ),
    ) {
        RetryableAsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )

        // Top-right indicator: stacked-squares for multi-media, play for a lone video.
        val indicator = when {
            mediaCount > 1 -> NostrVaultIcons.Layers
            isVideoUrl(url) -> NostrVaultIcons.PlayCircle
            else -> null
        }
        if (indicator != null) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(Color.Black.copy(alpha = 0.6f))
                    .padding(4.dp),
            ) {
                Icon(
                    imageVector = indicator,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
    }
}
