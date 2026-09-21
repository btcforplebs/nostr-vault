package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FeedThreadGrouping
import com.nostrvault.ui.theme.*

/**
 * Engagement counts shown beneath a condensed line. Zero fields simply don't
 * draw, so a caller that has no data can pass [CondensedEngagement.NONE].
 * Mirrors iOS `CondensedEngagement`.
 */
data class CondensedEngagement(
    val reactions: Int = 0,
    val reposts: Int = 0,
    val zaps: Int = 0,
    val topEmoji: String? = null,
) {
    val isEmpty: Boolean get() = reactions == 0 && reposts == 0 && zaps == 0

    companion object {
        val NONE = CondensedEngagement()
    }
}

/** How a [CondensedNoteLine] draws its own chrome. Mirrors iOS `CondensedNoteLine.Style`. */
enum class CondensedLineStyle {
    /** Standalone row in the feed: its own bordered card. */
    CARD,

    /** A line inside a thread card, which owns the chrome instead. */
    PLAIN,
}

/** One source for the indent so a line and the row that replaces it when tapped share a left edge. */
fun condensedIndentWidth(depth: Int): Dp =
    (minOf(depth, FeedThreadGrouping.MAX_DEPTH) * 14).dp

/** The rail that ties a reply back to what it answers. */
@Composable
fun ThreadRail(
    isOled: Boolean,
    modifier: Modifier = Modifier,
    themeColor: Color = LocalNostrVaultColors.current.primary,
) {
    Box(
        modifier = modifier
            .width(1.5.dp)
            .fillMaxHeight()
            .padding(end = 8.dp)
            .background(themeColor.copy(alpha = if (isOled) 0.35f else 0.22f)),
    )
}

/**
 * The single condensed representation of a note.
 *
 * Condensed is a property of the feed and nothing else: the feed's condensed
 * and threaded layouts both draw through here, and the thread view is always
 * expanded so a reply is one tap from wherever you landed. Keeping density on
 * one axis is what stops the two surfaces from disagreeing about how dense
 * "condensed" is. Mirrors iOS `CondensedNoteLine.swift`.
 */
@Composable
fun CondensedNoteLine(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    /** The author to credit when it isn't `note.pubkey` — a bare kind-6 repost shows the original author. */
    displayPubkey: String? = null,
    /** 0 is a root or standalone note; each step indents under a thread rail. */
    depth: Int = 0,
    style: CondensedLineStyle = CondensedLineStyle.CARD,
    /** Draws the purple selection treatment — the focused note in a thread card. */
    isFocused: Boolean = false,
    /** Replies in this thread directly under this note. */
    replyCount: Int = 0,
    /** Text to show instead of `note.content` — an article's title, or the original note behind an empty repost. */
    contentOverride: String? = null,
    mediaURLs: List<String> = emptyList(),
    engagement: CondensedEngagement = CondensedEngagement.NONE,
    showsMediaThumbnail: Boolean = true,
    onProfileClick: (String) -> Unit = {},
    onTap: (() -> Unit)? = null,
    themeColor: Color = LocalNostrVaultColors.current.primary,
    modifier: Modifier = Modifier,
) {
    val isOled = LocalOledMode.current
    val isRoot = depth == 0
    val authorPubkey = displayPubkey ?: note.pubkey
    val displayName = profile?.bestName ?: shortKey(authorPubkey)
    val displayContent = contentOverride ?: note.content

    val avatarSize = if (isRoot) 32.dp else 26.dp
    val nameSize = if (isRoot) 13.sp else 12.sp
    val bodySize = if (isRoot) 14.sp else 13.sp
    val bodyLineLimit = if (isRoot) 3 else 2

    val backgroundColor = when (style) {
        CondensedLineStyle.CARD ->
            if (isFocused) themeColor.copy(alpha = if (isOled) 0.08f else 0.12f) else SecondaryGroupedBg
        CondensedLineStyle.PLAIN ->
            if (isFocused) themeColor.copy(alpha = if (isOled) 0.10f else 0.12f) else Color.Transparent
    }
    val borderColor = when (style) {
        CondensedLineStyle.CARD ->
            if (isFocused) themeColor.copy(alpha = if (isOled) 0.6f else 0.4f)
            else themeColor.copy(alpha = if (isOled) 0.30f else 0.15f)
        CondensedLineStyle.PLAIN ->
            if (isFocused) themeColor.copy(alpha = if (isOled) 0.6f else 0.4f) else Color.Transparent
    }
    val borderWidth = when (style) {
        CondensedLineStyle.CARD -> if (isFocused) 1.5.dp else if (isOled) 1.dp else 0.5.dp
        CondensedLineStyle.PLAIN -> if (isFocused) 1.5.dp else 0.dp
    }
    val cornerRadius = if (style == CondensedLineStyle.CARD) 10.dp else 8.dp

    Row(
        modifier = modifier
            .padding(start = condensedIndentWidth(depth))
            .then(if (onTap != null) Modifier.clickable(onClick = onTap) else Modifier),
        verticalAlignment = Alignment.Top,
    ) {
        if (depth > 0) {
            ThreadRail(isOled = isOled, modifier = Modifier.heightIn(min = 1.dp), themeColor = themeColor)
        }

        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .weight(1f)
                .background(backgroundColor, RoundedCornerShape(cornerRadius))
                .border(borderWidth, borderColor, RoundedCornerShape(cornerRadius))
                .padding(
                    horizontal = if (style == CondensedLineStyle.CARD) 12.dp else 8.dp,
                    vertical = if (style == CondensedLineStyle.CARD) 8.dp else 6.dp,
                ),
        ) {
            AvatarImage(
                url = profile?.pictureURL,
                pubkey = authorPubkey,
                size = avatarSize,
                displayName = profile?.bestName,
                modifier = Modifier.clickable { onProfileClick(authorPubkey) },
            )

            Spacer(Modifier.width(8.dp))

            Column(modifier = Modifier.weight(1f)) {
                // Header: name · time · reply count / reply-or-repost marker
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = displayName,
                        color = PrimaryText,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = nameSize,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Text(
                        text = " · ${formatTimestamp(note.createdAt.time / 1000)}",
                        color = TertiaryText,
                        fontSize = 11.sp,
                        maxLines = 1,
                    )
                    Spacer(Modifier.weight(1f))
                    if (replyCount > 0) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            Icon(
                                imageVector = NostrVaultIcons.Chat,
                                contentDescription = null,
                                tint = SecondaryText.copy(alpha = if (isOled) 0.6f else 0.7f),
                                modifier = Modifier.size(9.dp),
                            )
                            Text(
                                text = "$replyCount",
                                color = SecondaryText.copy(alpha = if (isOled) 0.6f else 0.7f),
                                fontSize = 9.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    } else if (note.isReply && depth == 0) {
                        // A reply marker is noise inside a thread — the rail already says it.
                        Icon(
                            imageVector = NostrVaultIcons.Reply,
                            contentDescription = null,
                            tint = themeColor.copy(alpha = 0.7f),
                            modifier = Modifier.size(10.dp),
                        )
                    }
                    if (note.repostedBy != null) {
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            imageVector = NostrVaultIcons.Repost,
                            contentDescription = null,
                            tint = RepostGreen.copy(alpha = 0.7f),
                            modifier = Modifier.size(10.dp),
                        )
                    }
                }

                if (displayContent.isNotBlank()) {
                    Spacer(Modifier.height(2.dp))
                    val plainText = remember(note.id, displayContent, profiles) {
                        NostrMentions.toPlainText(displayContent, profiles, note.mediaURLs.toSet()).replace("\n", " ").trim()
                    }
                    Text(
                        text = plainText,
                        color = SecondaryText,
                        fontSize = bodySize,
                        maxLines = bodyLineLimit,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = (bodySize.value + 4).sp,
                    )
                }

                if (!engagement.isEmpty) {
                    Spacer(Modifier.height(2.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (engagement.reactions > 0) {
                            EngagementChip(text = engagement.topEmoji ?: "❤️", count = engagement.reactions)
                        }
                        if (engagement.zaps > 0) {
                            EngagementChip(icon = NostrVaultIcons.Zap, tint = ZapOrange, count = engagement.zaps)
                        }
                        if (engagement.reposts > 0) {
                            EngagementChip(icon = NostrVaultIcons.Repost, tint = RepostGreen, count = engagement.reposts)
                        }
                    }
                }
            }

            if (showsMediaThumbnail && mediaURLs.isNotEmpty()) {
                Spacer(Modifier.width(8.dp))
                CondensedMediaThumbnail(mediaURLs, isRoot)
            }
        }
    }
}

@Composable
private fun EngagementChip(
    count: Int,
    text: String? = null,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    tint: Color = SecondaryText,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        when {
            icon != null -> Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(8.dp))
            text != null -> Text(text, fontSize = 9.sp)
        }
        Text("$count", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun CondensedMediaThumbnail(mediaURLs: List<String>, isRoot: Boolean) {
    val context = LocalContext.current
    val size = if (isRoot) 80.dp else 56.dp
    Box {
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data(mediaURLs.first())
                .size(if (isRoot) 160 else 112)
                .crossfade(false)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(size)
                .clip(RoundedCornerShape(6.dp))
                .background(TertiaryGroupedBg),
        )
        if (mediaURLs.size > 1) {
            Text(
                text = "+${mediaURLs.size - 1}",
                color = Color.White,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(4.dp)
                    .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(50))
                    .padding(horizontal = 6.dp, vertical = 3.dp),
            )
        }
    }
}

private fun shortKey(key: String): String =
    if (key.length < 12) key else "npub…" + key.takeLast(6)
