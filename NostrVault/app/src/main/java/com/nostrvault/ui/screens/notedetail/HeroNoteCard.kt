package com.nostrvault.ui.screens

import com.nostrvault.ui.notification.LocalNotificationManager
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

// ── Hero note card ──────────────────────────────────────────────

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun HeroNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    /** Quoted events keyed by the lookup key `note.quotedEventIds` holds. */
    quotedNotes: Map<String, FeedNote> = emptyMap(),
    stats: NoteStats?,
    /** Who reacted with what and each zap's amount, for the engagement row. */
    engagement: EngagementDetails? = null,
    isLiked: Boolean,
    isReposted: Boolean = false,
    isOwnNote: Boolean,
    isFollowing: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onLike: () -> Unit,
    onLongPressLike: () -> Unit,
    onRepost: () -> Unit,
    onQuote: () -> Unit,
    onReply: () -> Unit,
    onFollow: () -> Unit,
    onUnfollow: () -> Unit,
    onBlock: () -> Unit,
    onDelete: () -> Unit,
    onReport: () -> Unit,
    onReactionsClick: () -> Unit,
    onRepostsClick: () -> Unit,
    onZapsClick: () -> Unit,
    onZap: () -> Unit,
    onShare: () -> Unit,
    onBroadcast: () -> Unit,
    /** Web of Trust for the author; null on your own notes. */
    onTrustWeb: (() -> Unit)? = null,
) {
    var showMoreMenu by remember { mutableStateOf(false) }
    val heroContext = LocalContext.current
    val heroClipboard = LocalClipboardManager.current
    val heroLane = LocalNotificationManager.current
    val cardShape = RoundedCornerShape(12.dp)

    // iOS mainNoteLayout: the same card as a focused feed row — 14pt padding,
    // a 2pt accent border and an accent-tinted glow (opacity 0.35, radius 8),
    // 16pt in from the screen edges. The glow is the accent, not a grey
    // elevation shadow, and the surface is opaque so it does not show through.
    Surface(
        color = SecondaryGroupedBg,
        shape = cardShape,
        border = androidx.compose.foundation.BorderStroke(2.dp, themeColor),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .shadow(
                elevation = 8.dp,
                shape = cardShape,
                ambientColor = themeColor.copy(alpha = 0.35f),
                spotColor = themeColor.copy(alpha = 0.35f),
            ),
    ) {
        Column(
            modifier = Modifier
                .background(themeColor.copy(alpha = HERO_TINT_ALPHA))
                .padding(14.dp),
        ) {
            // Author header, iOS `.wide` row: 40pt avatar, name with the
            // NIP-05 seal, relative time on the right, "reply to" under it.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                AvatarImage(
                    url = profile?.pictureURL,
                    pubkey = note.pubkey,
                    size = 40.dp,
                    displayName = profile?.bestName,
                    modifier = Modifier.clickable { onProfileClick(note.pubkey) },
                )
                Spacer(Modifier.width(12.dp))
                Column(
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = profile?.bestName ?: note.pubkey.take(8) + "...",
                            color = PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(1f, fill = false)
                                .clickable { onProfileClick(note.pubkey) },
                        )
                        if (!profile?.nip05.isNullOrBlank()) {
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                imageVector = NostrVaultIcons.Verified,
                                contentDescription = "Verified",
                                tint = androidx.compose.ui.graphics.Color(0xFF33CC99),
                                modifier = Modifier.size(14.dp),
                            )
                        }
                        if (note.isFromNostrVault) {
                            Spacer(Modifier.width(6.dp))
                            NostrVaultBadge(size = 12.dp)
                        }
                        Spacer(Modifier.weight(1f))
                        Text(
                            text = formatTimestamp(note.postedAt.time / 1000),
                            color = SecondaryText,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            letterSpacing = 0.2.sp,
                        )
                    }
                    val replyToPubkey = note.replyToPubkey
                    if (note.isReply && replyToPubkey != null) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = NostrVaultIcons.Reply,
                                contentDescription = null,
                                tint = themeColor.copy(alpha = 0.6f),
                                modifier = Modifier.size(10.dp),
                            )
                            Spacer(Modifier.width(3.dp))
                            Text(
                                text = "reply to ${profiles[replyToPubkey]?.bestName ?: replyToPubkey.take(8) + "..."}",
                                color = SecondaryText.copy(alpha = 0.7f),
                                fontSize = 10.sp,
                                fontFamily = FontFamily.Monospace,
                                letterSpacing = 0.1.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }

                // More menu button. Same component as every other note's menu —
                // this one carries Follow/Unfollow as well, because the focused
                // note is the only place that offers them.
                Box {
                    IconButton(onClick = { showMoreMenu = true }) {
                        Icon(NostrVaultIcons.More, "More", tint = SecondaryText, modifier = Modifier.size(18.dp))
                    }
                    NoteActionsMenu(
                        expanded = showMoreMenu,
                        actions = buildList {
                            add(NoteAction(NostrVaultIcons.Share, "Share", onClick = onShare))
                            add(
                                NoteAction(NostrVaultIcons.LinkIcon, "Copy link") {
                                    val nevent = HavenBridge.encodeNevent(
                                        note.effectiveEventId,
                                        note.effectiveAuthor,
                                        note.effectiveKind,
                                    ) ?: HavenBridge.hexToNote1(note.effectiveEventId)
                                        ?: note.effectiveEventId
                                    heroClipboard.setText(AnnotatedString(threadLink(nevent)))
                                    heroLane.showFeedback("Link copied", NostrVaultIcons.LinkIcon)
                                },
                            )
                            // Same as every other note's menu (NoteCard).
                            if (note.content.isNotBlank()) {
                                add(
                                    NoteAction(NostrVaultIcons.Copy, "Copy text") {
                                        heroClipboard.setText(AnnotatedString(
                                            com.nostrvault.ui.components.NostrMentions.toPlainText(note.content, profiles).trim()
                                        ))
                                        heroLane.showFeedback("Text copied", NostrVaultIcons.Copy)
                                    },
                                )
                            }
                            add(NoteAction(NostrVaultIcons.Relay, "Broadcast", onClick = onBroadcast))
                            if (isOwnNote) {
                                add(NoteAction(NostrVaultIcons.Delete, "Delete Post", destructive = true, onClick = onDelete))
                            } else {
                                if (isFollowing) {
                                    add(NoteAction(NostrVaultIcons.Blocked, "Unfollow", onClick = onUnfollow))
                                } else {
                                    add(NoteAction(NostrVaultIcons.PersonAdd, "Follow", onClick = onFollow))
                                }
                                // Same names and order as the feed's ⋯ menu.
                                add(NoteAction(NostrVaultIcons.Alert, "Report Post", destructive = true, onClick = onReport))
                                add(NoteAction(NostrVaultIcons.Blocked, "Block User", destructive = true, onClick = onBlock))
                            }
                        },
                        onDismiss = { showMoreMenu = false },
                    )
                }
            }

            Spacer(Modifier.height(10.dp))

            // Content. A poll draws its question and options as the card,
            // bigger here, with who picked each option.
            val poll = remember(note.id, note.kind) { note.poll }
            if (poll != null) {
                PollCard(poll = poll, isFocused = true, hiddenURLs = (note.mediaURLs + note.cardLinkURLs).toSet())
                Spacer(Modifier.height(12.dp))
            } else if (note.content.isNotBlank()) {
                val mediaSet = remember(note.mediaURLs) { note.mediaURLs.toSet() }
                val linkSet = remember(note.cardLinkURLs) { note.cardLinkURLs.toSet() }
                TranslatableNoteText(
                    noteKey = note.effectiveEventId,
                    content = note.content,
                    profiles = profiles,
                    mediaURLs = mediaSet,
                    linkURLs = linkSet,
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                    selectable = true,
                ) {
                    // Long-press selects the focused note's text (iOS
                    // FeedNoteRow `.textSelection(.enabled)`).
                    NostrContentText(
                        content = note.content,
                        profiles = profiles,
                        mediaURLs = mediaSet,
                        linkURLs = linkSet,
                        onProfileClick = onProfileClick,
                        fontSize = 17.sp,
                        lineHeight = 24.sp,
                        selectable = true,
                    )
                }
                Spacer(Modifier.height(12.dp))
            }

            // Media, then links, then quotes, as on iOS.
            if (note.mediaURLs.isNotEmpty()) {
                MediaPreviewRow(urls = note.mediaURLs, tags = note.tags)
                Spacer(Modifier.height(12.dp))
            }

            // One card per link: the URLs are out of the text above (#170).
            for (link in note.cardLinkURLs) {
                LinkPreviewCard(url = link)
                Spacer(Modifier.height(12.dp))
            }

            // Quoted events. The reference itself is stripped out of the text
            // above, so without this the focused note silently loses whatever
            // it was quoting — on the one screen opened to read it in full.
            for (qid in note.quotedEventIds) {
                val quoted = quotedNotes[qid]
                if (quoted != null) {
                    QuotedNoteCard(
                        note = quoted,
                        profile = profiles[quoted.pubkey],
                        profiles = profiles,
                        onClick = onNoteClick,
                        onArticleClick = onArticleClick,
                    )
                } else {
                    QuotedNotePlaceholder(identifier = qid, onClick = onNoteClick)
                }
                Spacer(Modifier.height(12.dp))
            }

            // The time is in the header, relative, as on iOS — the card no
            // longer repeats it as a full date under the body.
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            // Engagement row — only shown when at least one count is non-zero.
            // Reactions as per-emoji pills, zaps as "count · total sats", the
            // way iOS shows them. The per-event details arrive after the
            // counts, so the counts stand in until then. Reactions are dropped
            // entirely in Zaps Only mode.
            val zapsOnly = LocalZapsOnlyMode.current
            val emojiGroups = remember(engagement?.reactions, stats?.reactions, zapsOnly) {
                when {
                    zapsOnly -> emptyList()
                    !engagement?.reactions.isNullOrEmpty() -> EngagementSummary.groupReactions(engagement!!.reactions)
                    (stats?.reactions ?: 0) > 0 -> listOf(EngagementSummary.EmojiGroup("\u2764\uFE0F", stats!!.reactions))
                    else -> emptyList()
                }
            }
            val reposts = engagement?.reposts?.map { it.pubkey }?.distinct()?.size?.takeIf { it > 0 }
                ?: stats?.reposts ?: 0
            val zapDetails = engagement?.zaps.orEmpty()
            val zapCount = if (zapDetails.isNotEmpty()) zapDetails.size else stats?.zaps ?: 0
            val zapSats = if (zapDetails.isNotEmpty()) zapDetails.sumOf { it.amountSats } else stats?.zapAmountSats ?: 0L
            if (emojiGroups.isNotEmpty() || reposts > 0 || zapCount > 0) {
                Spacer(Modifier.height(12.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (emojiGroups.isNotEmpty()) {
                        val shown = emojiGroups.take(EngagementSummary.VISIBLE_EMOJI_GROUPS)
                        EngagementPill(
                            description = emojiGroups.joinToString(prefix = "Reactions: ") { "${it.emoji} ${it.count}" },
                            onClick = onReactionsClick,
                        ) {
                            shown.forEach { group ->
                                Text(group.emoji, fontSize = 12.sp)
                                Spacer(Modifier.width(2.dp))
                                Text("${group.count}", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                                Spacer(Modifier.width(4.dp))
                            }
                            if (emojiGroups.size > shown.size) {
                                Text("+${emojiGroups.size - shown.size}", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                            }
                        }
                    }
                    if (zapCount > 0) {
                        val text = EngagementSummary.zapText(zapCount, zapSats)
                        EngagementPill(description = "Zaps: $text sats", onClick = onZapsClick) {
                            Icon(NostrVaultIcons.Zap, contentDescription = null, tint = ZapOrange, modifier = Modifier.size(12.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(text, color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                        }
                    }
                    if (reposts > 0) {
                        EngagementPill(description = "Reposts: $reposts", onClick = onRepostsClick) {
                            Icon(NostrVaultIcons.Repost, contentDescription = null, tint = RepostGreen, modifier = Modifier.size(12.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("$reposts", color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            }

            Spacer(Modifier.height(8.dp))

            // Action buttons. The real `EngagementBar`, not a copy of it — this
            // was a hand-duplicated seven-button row under a comment claiming it
            // was identical, which is how it kept Share and Broadcast inline
            // while every other note on this screen had moved them to the menu.
            EngagementBar(
                noteId = note.effectiveEventId,
                isLiked = isLiked,
                isZapped = false,
                isReposted = isReposted,
                onReply = { onReply() },
                onRepost = { onRepost() },
                onQuote = { onQuote() },
                onLike = { onLike() },
                onZap = { onZap() },
                onLongPressLike = { onLongPressLike() },
                onTrustWeb = onTrustWeb,
            )
        }
    }
}

/**
 * The focused card's accent wash. iOS lays havenPurple at 0.015 over an opaque
 * card; 0.04 is what the focused [NoteCard] uses on Android, so the hero and a
 * focused reply read as the same card.
 */
private const val HERO_TINT_ALPHA = 0.04f
