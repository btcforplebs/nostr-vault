package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextOverflow
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.LiveFeedService
import com.nostrvault.ui.components.LiveStreamThumbnail
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

    LazyColumn(contentPadding = contentPadding, modifier = Modifier.fillMaxSize()) {
        // Global with no web of trust yet shows everyone (minus adult
        // streams); say so, as the topic feed does. iOS liveUnfilteredBanner.
        if (!scopeFollowing && globalGate == LiveFeedService.GlobalGate.NewAccount) {
            item(key = "unfiltered") {
                Text(
                    text = "Unfiltered: people you don't know yet",
                    color = SecondaryText,
                    fontSize = 12.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp)
                        .semantics {
                            contentDescription = "Unfiltered. These streams are from people you don't know yet."
                        },
                )
            }
        }
        items(streams, key = { it.address }) { stream ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onStreamClick(stream) }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                // The live frame, else the cover; refetched while on screen.
                if (stream.previewImageUrls.isNotEmpty()) {
                    LiveStreamThumbnail(
                        urls = stream.previewImageUrls,
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(16f / 9f)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                    Spacer(Modifier.height(8.dp))
                }
                Text(
                    text = stream.title ?: "Untitled stream",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = buildString {
                        append(profiles[stream.hostPubkey]?.bestName ?: stream.hostPubkey.take(8))
                        stream.participants?.let { append(" · $it watching") }
                    },
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
        }
    }
}
