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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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

/**
 * The rail that ties a reply back to what it answers: a line down the left edge,
 * as tall as the row, with the content set in past it. Mirrors iOS
 * `CondensedNoteLine.rail` (1.5 wide, 8 of space after).
 *
 * Drawn behind rather than as a child Box: a `fillMaxHeight` child of a row in a
 * lazy list gets no height to fill, and padding inside its 1.5 dp width left it
 * nothing to paint, so the line never showed on Android.
 */
fun Modifier.threadRail(color: Color, isOled: Boolean): Modifier =
    drawBehind {
        drawRect(
            color = color.copy(alpha = if (isOled) 0.35f else 0.22f),
            size = Size(THREAD_RAIL_WIDTH.toPx(), size.height),
        )
    }.padding(start = THREAD_RAIL_WIDTH + 8.dp)

private val THREAD_RAIL_WIDTH = 1.5.dp

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
    // From Settings: a feed row (CARD) is Compact View; a line in a thread
    // card (PLAIN) is Threaded View, where replies show one fewer than the root.
    val bodyLineLimit = LocalFeedLineLimits.current.let { limits ->
        if (style == CondensedLineStyle.CARD) limits.compactLines else limits.threadedLines(isRoot)
    }

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
            .then(if (onTap != null) Modifier.clickable(onClick = onTap) else Modifier)
            .then(if (depth > 0) Modifier.threadRail(themeColor, isOled) else Modifier),
        verticalAlignment = Alignment.Top,
    ) {
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

                // Every URL comes out of the line (#170 parity); links come
                // from the text actually shown, which an override replaces.
                val (bodyMedia, bodyLinks) = remember(displayContent, mediaURLs, note.mediaURLs) {
                    val media = FeedNote.parseMediaURLs(displayContent).toSet() + mediaURLs + note.mediaURLs
                    media to FeedNote.parseLinkURLs(displayContent, media)
                }
                val plainText = remember(note.id, displayContent, profiles, bodyMedia, bodyLinks) {
                    NostrMentions.collapseGaps(
                        NostrMentions.toPlainText(displayContent, profiles, bodyMedia, bodyLinks.toSet()).replace("\n", " ")
                    ).trim()
                }
                if (plainText.isNotBlank()) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = plainText,
                        color = SecondaryText,
                        fontSize = bodySize,
                        maxLines = bodyLineLimit,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = (bodySize.value + 4).sp,
                    )
                }

                if (bodyLinks.isNotEmpty()) {
                    Spacer(Modifier.height(3.dp))
                    CondensedLinkChip(bodyLinks, themeColor)
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

/** The first link's domain, `+N` for the rest: links the line no longer prints. */
@Composable
private fun CondensedLinkChip(links: List<String>, tint: Color) {
    val label = if (links.size == 1) "Link to ${linkDomain(links[0])}" else "${links.size} links"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = label },
    ) {
        Icon(
            imageVector = NostrVaultIcons.LinkIcon,
            contentDescription = null,
            tint = tint.copy(alpha = 0.8f),
            modifier = Modifier.size(10.dp),
        )
        Text(
            text = linkDomain(links[0]) + if (links.size > 1) " +${links.size - 1}" else "",
            color = SecondaryText,
            fontSize = 11.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
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
