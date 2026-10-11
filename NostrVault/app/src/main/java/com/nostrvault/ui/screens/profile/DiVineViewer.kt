package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*

/** A diVine's poster, 9:16, with a play mark. */
@Composable
internal fun DiVineTile(reel: com.nostrvault.data.model.Reel, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.BottomStart,
        modifier = modifier
            .aspectRatio(9f / 16f)
            .clip(RoundedCornerShape(6.dp))
            .background(Color.Black)
            .clickable(onClickLabel = reel.title ?: "diVine", onClick = onClick),
    ) {
        reel.posterUrl?.let { poster ->
            AsyncImage(
                model = poster,
                contentDescription = reel.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.matchParentSize(),
            )
        }
        Icon(
            NostrVaultIcons.PlayArrow,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.padding(6.dp).size(16.dp),
        )
    }
}

/** This person's diVines full screen, one page each, the visible one playing. */
@Composable
internal fun DiVineViewer(reels: List<com.nostrvault.data.model.Reel>, startIndex: Int, onDismiss: () -> Unit) {
    val pagerState = rememberPagerState(initialPage = startIndex, pageCount = { reels.size })
    androidx.activity.compose.BackHandler(onBack = onDismiss)
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        androidx.compose.foundation.pager.VerticalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                // Only the visible page gets a player, to keep memory at one instance.
                if (page == pagerState.currentPage) {
                    com.nostrvault.ui.components.VideoPlayer(uri = reels[page].videoUrl, modifier = Modifier.fillMaxSize())
                } else {
                    reels[page].posterUrl?.let {
                        AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                    }
                }
            }
        }
        IconButton(
            onClick = onDismiss,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(12.dp),
        ) {
            Icon(NostrVaultIcons.Dismiss, "Close", tint = Color.White, modifier = Modifier.size(28.dp))
        }
    }
}
