package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.ReactionDetail
import com.nostrvault.data.model.RepostDetail
import com.nostrvault.data.model.ZapDetail
import com.nostrvault.ui.theme.*

/**
 * Bottom sheets showing who reacted, zapped, or reposted a note.
 * Mirrors iOS ReactorsListView, ZappersListView, RepostersListView.
 */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReactorsSheet(
    reactions: List<ReactionDetail>,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SecondaryGroupedBg,
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 32.dp),
        ) {
            Text(
                text = "Reactions",
                color = PrimaryText,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )
            Spacer(Modifier.height(16.dp))

            if (reactions.isEmpty()) {
                Text(
                    text = "No reactions yet",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .padding(vertical = 24.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.heightIn(max = 400.dp),
                ) {
                    items(reactions, key = { it.id }) { reaction ->
                        val profile = profiles[reaction.pubkey]
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onProfileClick(reaction.pubkey) }
                                .padding(horizontal = 20.dp, vertical = 8.dp),
                        ) {
                            AvatarImage(
                                url = profile?.pictureURL,
                                pubkey = reaction.pubkey,
                                size = 40.dp,
                                displayName = profile?.bestName,
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                text = profile?.bestName ?: "${reaction.pubkey.take(8)}...",
                                color = PrimaryText,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                text = reactionDisplayEmoji(reaction.emoji),
                                fontSize = 20.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ZappersSheet(
    zaps: List<ZapDetail>,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SecondaryGroupedBg,
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 32.dp),
        ) {
            Text(
                text = "Zaps",
                color = PrimaryText,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )
            Spacer(Modifier.height(16.dp))

            if (zaps.isEmpty()) {
                Text(
                    text = "No zaps yet",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .padding(vertical = 24.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.heightIn(max = 400.dp),
                ) {
                    items(zaps, key = { it.id }) { zap ->
                        val profile = profiles[zap.zapperPubkey]
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onProfileClick(zap.zapperPubkey) }
                                .padding(horizontal = 20.dp, vertical = 8.dp),
                        ) {
                            AvatarImage(
                                url = profile?.pictureURL,
                                pubkey = zap.zapperPubkey,
                                size = 40.dp,
                                displayName = profile?.bestName,
                            )
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = profile?.bestName ?: "${zap.zapperPubkey.take(8)}...",
                                    color = PrimaryText,
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (zap.comment.isNotBlank()) {
                                    Text(
                                        text = remember(zap.comment, profiles) {
                                            NostrMentions.toPlainText(zap.comment, profiles)
                                        },
                                        color = SecondaryText,
                                        fontSize = 13.sp,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                            Spacer(Modifier.width(12.dp))
                            Text(
                                text = formatSats(zap.amountSats),
                                color = ZapOrange,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RepostersSheet(
    reposts: List<RepostDetail>,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onDismiss: () -> Unit,
    /** The same list of people serves quotes too ("Quoted By", iOS QuotersListView). */
    title: String = "Reposts",
    emptyText: String = "No reposts yet",
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SecondaryGroupedBg,
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 32.dp),
        ) {
            Text(
                text = title,
                color = PrimaryText,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )
            Spacer(Modifier.height(16.dp))

            if (reposts.isEmpty()) {
                Text(
                    text = emptyText,
                    color = SecondaryText,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .padding(vertical = 24.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.heightIn(max = 400.dp),
                ) {
                    items(reposts, key = { it.id }) { repost ->
                        val profile = profiles[repost.pubkey]
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onProfileClick(repost.pubkey) }
                                .padding(horizontal = 20.dp, vertical = 8.dp),
                        ) {
                            AvatarImage(
                                url = profile?.pictureURL,
                                pubkey = repost.pubkey,
                                size = 40.dp,
                                displayName = profile?.bestName,
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                text = profile?.bestName ?: "${repost.pubkey.take(8)}...",
                                color = PrimaryText,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun formatSats(sats: Long): String {
    return when {
        sats >= 1_000_000 -> "${sats / 1_000_000}.${(sats % 1_000_000) / 100_000}M sats"
        sats >= 1_000 -> "${sats / 1_000}.${(sats % 1_000) / 100}K sats"
        else -> "$sats sats"
    }
}
