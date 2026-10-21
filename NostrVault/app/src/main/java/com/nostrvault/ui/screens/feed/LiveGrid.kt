package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.LiveFeedService
import com.nostrvault.ui.components.LiveStreamCard
import com.nostrvault.ui.components.liveHostFallback
import com.nostrvault.ui.components.NostrWebLinks
import com.nostrvault.ui.theme.*

/**
 * Live streams (NIP-53). Only playable ones reach here — LiveFeedService drops
 * anything that has ended or whose URL the player cannot open, because a tile
 * for one of those can only disappoint.
 */
@Composable
internal fun LiveGrid(
    streams: List<LiveStream>,
    profiles: Map<String, FeedProfile>,
    isLoading: Boolean,
    contentPadding: PaddingValues,
    onStreamClick: (LiveStream) -> Unit,
    onRefresh: () -> Unit,
    /** No relay answered the last load. */
    loadFailed: Boolean = false,
    scopeFollowing: Boolean = false,
    onShowGlobal: () -> Unit = {},
    /** Following, and the account follows nobody. */
    followSetIsEmpty: Boolean = false,
    /** Who Global let in on the last load (LiveFeedService.globalGate). */
    globalGate: LiveFeedService.GlobalGate? = null,
) {
    val colors = LocalNostrVaultColors.current
    if (streams.isEmpty()) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
            if (isLoading) {
                CircularProgressIndicator(color = colors.primary)
            } else {
                ScopedEmptyPlaceholder(
                    FeedMode.LIVE, scopeFollowing, onRefresh, onShowGlobal,
                    loadFailed = loadFailed,
                    liveFollowSetIsEmpty = followSetIsEmpty,
                    liveGate = if (scopeFollowing) null else globalGate,
                )
            }
        }
        return
    }

    // iOS: an adaptive grid of boxed cards, at least 170 wide, 12 apart,
    // 16 in from the sides and 16 above and below.
    val layoutDirection = LocalLayoutDirection.current
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 170.dp),
        contentPadding = PaddingValues(
            start = contentPadding.calculateStartPadding(layoutDirection) + 16.dp,
            end = contentPadding.calculateEndPadding(layoutDirection) + 16.dp,
            top = contentPadding.calculateTopPadding() + 16.dp,
            bottom = contentPadding.calculateBottomPadding() + 16.dp,
        ),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        // Global with no web of trust yet shows everyone (minus adult
        // streams); say so, as the topic feed does. iOS liveUnfilteredBanner.
        if (!scopeFollowing && globalGate == LiveFeedService.GlobalGate.NewAccount) {
            item(key = "unfiltered", span = { GridItemSpan(maxLineSpan) }) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics(mergeDescendants = true) {
                            contentDescription = "Unfiltered. These streams are from people you don't know yet."
                        },
                ) {
                    Icon(
                        Icons.Outlined.Visibility,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "Unfiltered: people you don't know yet",
                        color = SecondaryText,
                        fontSize = 12.sp,
                    )
                }
            }
        }
        items(streams, key = { it.address }) { stream ->
            LiveGridTile(
                stream = stream,
                hostName = profiles[stream.hostPubkey]?.bestName ?: liveHostFallback(stream.hostPubkey),
                onClick = { onStreamClick(stream) },
            )
        }
    }
}

/**
 * One grid tile: tap plays, long-press offers the stream on the web. The menu
 * is here, not on the card, as on iOS: the card is also drawn inside notes,
 * whose own long-press menu it would hide.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LiveGridTile(stream: LiveStream, hostName: String, onClick: () -> Unit) {
    val context = LocalContext.current
    var showMenu by remember { mutableStateOf(false) }
    val webLink = remember(stream.address) { NostrWebLinks.forStream(stream) }
    Box {
        LiveStreamCard(
            stream = stream,
            hostName = hostName,
            isLive = true,
            thumbnailHeight = 120.dp,
            modifier = Modifier.combinedClickable(
                onClick = onClick,
                onLongClick = if (webLink != null) ({ showMenu = true }) else null,
            ),
        )
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            webLink?.let { link ->
                DropdownMenuItem(
                    text = { Text(link.label) },
                    leadingIcon = { Icon(NostrVaultIcons.OpenExternal, contentDescription = null) },
                    onClick = {
                        showMenu = false
                        NostrWebLinks.open(context, link.url)
                    },
                )
            }
        }
    }
}
