package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import androidx.compose.ui.semantics.contentDescription
import com.nostrvault.ui.theme.*
import kotlin.math.max

// ── Parent note preview ──────────────────────────────────────────

/**
 * Parent note preview shown inside a reply card when the parent
 * is not the immediately preceding card in the feed.
 * Matches the iOS layout: 40dp avatar + connector line on the left,
 * name/timestamp + content + media on the right.
 */
@Composable
internal fun ParentNotePreview(
    parentNote: FeedNote,
    parentProfile: FeedProfile?,
    connectorColor: Color,
    onClick: () -> Unit,
    profiles: Map<String, FeedProfile> = emptyMap(),
    avatarMenu: AvatarMenuActions? = null,
    onProfileClick: (String) -> Unit = {},
    onTrustWeb: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current

    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clickable(onClick = onClick),
    ) {
        // Left column: avatar + connector line (matches iOS VStack)
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxHeight(),
        ) {
            // Tapping it opens the same quick menu as the note's own avatar;
            // without a menu it stays part of the preview's tap (iOS).
            if (avatarMenu != null) {
                AvatarWithMenu(
                    pubkey = parentNote.pubkey,
                    displayName = parentProfile?.bestName ?: shortKey(parentNote.pubkey),
                    menu = avatarMenu,
                    onProfileClick = onProfileClick,
                    onTrustWeb = onTrustWeb,
                ) { avatarModifier ->
                    AvatarImage(
                        url = parentProfile?.pictureURL,
                        pubkey = parentNote.pubkey,
                        size = 40.dp,
                        displayName = parentProfile?.bestName,
                        modifier = avatarModifier,
                    )
                }
            } else {
                AvatarImage(
                    url = parentProfile?.pictureURL,
                    pubkey = parentNote.pubkey,
                    size = 40.dp,
                    displayName = parentProfile?.bestName,
                )
            }
            // Connector line extending down to current note
            Box(
                modifier = Modifier
                    .width(2.dp)
                    .weight(1f)
                    .background(connectorColor),
            )
        }

        Spacer(Modifier.width(12.dp))

        // Right column: header + content + media
        Column(modifier = Modifier.weight(1f)) {
            // Header (iOS): name, seal, badge, then the time right-aligned
            // on the same line in 11pt monospace. The name opens the profile.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = 4.dp),
            ) {
                Text(
                    text = parentProfile?.bestName ?: shortKey(parentNote.pubkey),
                    color = Color(0xFFD9D9D9), // iOS: rgb(0.85, 0.85, 0.85)
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .weight(1f, fill = false)
                        .clickable { onProfileClick(parentNote.pubkey) },
                )

                if (!parentProfile?.nip05.isNullOrBlank()) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        imageVector = NostrVaultIcons.Verified,
                        contentDescription = "Verified",
                        tint = Color(0xFF33CC99),
                        modifier = Modifier.size(12.dp),
                    )
                }
                if (parentNote.isFromNostrVault) {
                    Spacer(Modifier.width(6.dp))
                    NostrVaultBadge(size = 10.dp)
                }

                Spacer(Modifier.weight(1f))
                Spacer(Modifier.width(6.dp))

                Text(
                    text = formatTimestamp(parentNote.createdAt.time / 1000),
                    color = SecondaryText,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 0.2.sp,
                )
            }

            // Content text (2 lines max, matching iOS)
            if (parentNote.content.isNotBlank()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = remember(parentNote.content, profiles) {
                        NostrMentions.toPlainText(parentNote.content, profiles, parentNote.mediaURLs.toSet()).trim()
                    },
                    color = Color(0xFFB3B3B3), // iOS: rgb(0.7, 0.7, 0.7)
                    fontSize = 14.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            // First media thumbnail (matching iOS 150pt max height)
            if (parentNote.mediaURLs.isNotEmpty()) {
                Spacer(Modifier.height(6.dp))
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(parentNote.mediaURLs.first())
                        .size(360)
                        .crossfade(100)
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 150.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(TertiaryGroupedBg),
                )
            }
        }
    }
}

/** The parent never arrived — likely on no relay we asked. iOS FeedView parentFetchFailed. */
@Composable
internal fun ParentNoteFailed(onRetry: (() -> Unit)?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Alert,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(12.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(
            text = "Could not load original note",
            color = SecondaryText,
            fontSize = 13.sp,
            modifier = Modifier.weight(1f),
        )
        if (onRetry != null) {
            TextButton(onClick = onRetry) {
                Text(
                    text = "Retry",
                    color = LocalNostrVaultColors.current.primary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

/**
 * Skeleton placeholder for a parent note that is still being fetched.
 * Matches the iOS skeleton layout (circle + placeholder bars + connector).
 */
@Composable
internal fun ParentNoteSkeleton(
    connectorColor: Color,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min),
    ) {
        // Left column: circle placeholder + connector
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxHeight(),
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(TertiaryGroupedBg),
            )
            Box(
                modifier = Modifier
                    .width(2.dp)
                    .weight(1f)
                    .background(connectorColor),
            )
        }

        Spacer(Modifier.width(12.dp))

        // Right column: one line-height bar per line of the loaded preview
        // (name, timestamp, two lines of content), in the same text styles, so
        // the card is already the height the parent will need when it arrives.
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(top = 4.dp),
        ) {
            SkeletonTextLine(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, widthFraction = 0.35f, color = TertiaryGroupedBg)
            SkeletonTextLine(fontSize = 11.sp, widthFraction = 0.12f, color = TertiaryGroupedBg)
            Spacer(Modifier.height(2.dp))
            SkeletonTextLine(fontSize = 14.sp, widthFraction = 0.9f, color = TertiaryGroupedBg)
            SkeletonTextLine(fontSize = 14.sp, widthFraction = 0.55f, color = TertiaryGroupedBg)
        }
    }
}
