package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.*

/**
 * Compact/condensed note card for dense feed viewing.
 * Shows a row with small avatar, name+time header, 2-line content,
 * and optional media thumbnail. No engagement bar — tap opens detail.
 */
@Composable
fun CompactNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    repostedByProfile: FeedProfile? = null,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current

    Surface(
        shape = RoundedCornerShape(10.dp),
        color = SecondaryGroupedBg.copy(alpha = 0.85f),
        border = BorderStroke(0.8.dp, colors.primary.copy(alpha = 0.12f)),
        modifier = modifier
            .fillMaxWidth()
            .clickable { onNoteClick(note.id) },
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.padding(10.dp),
        ) {
            // Avatar
            AvatarImage(
                url = profile?.pictureURL,
                pubkey = note.pubkey,
                size = 32.dp,
                displayName = profile?.bestName,
                modifier = Modifier.clickable { onProfileClick(note.pubkey) },
            )

            Spacer(Modifier.width(8.dp))

            // Center content
            Column(
                modifier = Modifier.weight(1f),
            ) {
                // Header: name · time + optional indicators
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Repost indicator
                    if (note.repostedBy != null) {
                        Icon(
                            imageVector = NostrVaultIcons.Repost,
                            contentDescription = null,
                            tint = RepostGreen,
                            modifier = Modifier.size(10.dp),
                        )
                        Spacer(Modifier.width(3.dp))
                    }

                    // Reply indicator
                    if (note.isReply) {
                        Icon(
                            imageVector = NostrVaultIcons.Reply,
                            contentDescription = null,
                            tint = SecondaryText,
                            modifier = Modifier.size(10.dp),
                        )
                        Spacer(Modifier.width(3.dp))
                    }

                    Text(
                        text = if (note.repostedBy != null) {
                            repostedByProfile?.bestName ?: note.repostedBy!!.take(8) + "..."
                        } else {
                            profile?.bestName ?: note.pubkey.take(8) + "..."
                        },
                        color = PrimaryText,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )

                    Text(
                        text = " · ${formatTimestamp(note.createdAt.time / 1000)}",
                        color = TertiaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                    )
                }

                // Body text (plain, 3 lines max). Memoize the regex-based mention
                // stripping so it doesn't re-run on every recomposition (e.g. each
                // throttled profile-map update) while scrolling the compact feed.
                if (note.content.isNotBlank()) {
                    Spacer(Modifier.height(2.dp))
                    val plainText = remember(note.id, note.content, profiles) {
                        NostrMentions.toPlainText(note.content, profiles, note.mediaURLs.toSet()).replace("\n", " ").trim()
                    }
                    Text(
                        text = plainText,
                        color = SecondaryText,
                        fontSize = 13.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = 17.sp,
                    )
                }
            }

            // Optional media thumbnail
            if (note.mediaURLs.isNotEmpty()) {
                val context = LocalContext.current
                Spacer(Modifier.width(8.dp))
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(note.mediaURLs.first())
                        .size(128) // 64dp at 2x density
                        .crossfade(false) // Disable crossfade for instant rendering
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(64.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(TertiaryGroupedBg),
                )
            }
        }
    }
}
