package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.notification.LocalNotificationManager
import com.nostrvault.relay.HavenBridge
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedHighlight
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PostEngagement
import com.nostrvault.data.model.poll
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.nostrvault.ui.theme.*

/**
 * Reusable note card used across Feed, Profile, Search, and NoteDetail screens.
 * Renders author header, content, media thumbnails, and engagement actions.
 */
@Composable
fun NoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    quotedNotes: Map<String, FeedNote> = emptyMap(),
    isLiked: Boolean = false,
    isZapped: Boolean = false,
    isReposted: Boolean = false,
    isFocused: Boolean = false,
    showReplyContext: Boolean = false,
    /** The parent is the row above: no parent preview (iOS showParent: !parentIsNext). */
    parentIsNext: Boolean = false,
    parentNote: FeedNote? = null,
    repostedByProfile: FeedProfile? = null,
    replyToProfile: FeedProfile? = null,
    /**
     * Shown in place of the body while a bare repost waits for its original,
     * or once no relay had it. Null shows the body.
     */
    repostPlaceholder: RepostPlaceholder? = null,
    onNoteClick: (String) -> Unit,
    /**
     * Where a quoted long-form post opens. Null falls back to [onNoteClick],
     * which lands on the note screen and would show the Markdown source.
     */
    onArticleClick: ((String) -> Unit)? = null,
    onProfileClick: (String) -> Unit,
    onLike: ((String) -> Unit)? = null,
    onRepost: ((String) -> Unit)? = null,
    onZap: ((String) -> Unit)? = null,
    onReply: ((String) -> Unit)? = null,
    onQuote: ((String) -> Unit)? = null,
    onBroadcast: ((String) -> Unit)? = null,
    /** Opens the Web of Trust map for the author's pubkey. Null hides the button (pass null on your own notes). */
    onTrustWeb: ((String) -> Unit)? = null,
    /**
     * Overflow-menu handlers. The menu is anchored to the card's own button, so
     * the card owns it rather than a screen-level dialog keyed by note id.
     *
     * Copy link needs nothing from the caller and is always offered, so every
     * card has a menu — a search result gets one item, the feed gets three.
     */
    isOwnNote: Boolean = false,
    onReport: (() -> Unit)? = null,
    onBlock: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
    onLongPressLike: ((String) -> Unit)? = null,
    /** Long-press on the bolt: pick an amount. Tap ([onZap]) zaps the default at once. */
    onLongPressZap: ((String) -> Unit)? = null,
    /** The author has no lightning address: the bolt draws faint (iOS). */
    zapDimmed: Boolean = false,
    /** Asks relays for the parent again after "Could not load original note". */
    onRetryParent: ((String) -> Unit)? = null,
    /** Videos play inline, muted and looping, while most on screen (Settings > Autoplay Videos). */
    autoplayVideos: Boolean = false,
    /** With it, an avatar tap opens Follow / Block, and the name opens the profile. */
    avatarMenu: AvatarMenuActions? = null,
    /**
     * Likes, reposts, replies, quotes and zap sats, where the screen fetched
     * them (profiles, [com.nostrvault.service.ProfileEngagementStore]). Each
     * number goes on its own button; null leaves the buttons bare.
     */
    engagement: PostEngagement? = null,
    /** The 🔥 rank line at the top, in the Popular feed. Null draws none. */
    popularRank: PopularRank? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val isOled = LocalOledMode.current

    // Overflow menu. Built here rather than by each screen so that the item
    // order and wording are one definition; which items exist is the caller's,
    // because a search result and the feed genuinely differ.
    var showMoreMenu by remember { mutableStateOf(false) }
    val menuContext = LocalContext.current
    val menuClipboard = LocalClipboardManager.current
    val menuLane = LocalNotificationManager.current
    val moreActions = buildList {
        // Share and Broadcast live here rather than in the action row: neither
        // carries a count, both are secondary to Reply/Repost/Like/Zap, and the
        // row does not have the width for seven buttons plus three counts on a
        // 360dp phone. Share also sits next to Copy link, which is the same
        // intent spelled twice when they are on different surfaces.
        add(NoteAction(NostrVaultIcons.Share, "Share") { shareNote(menuContext, note) })
        add(
            NoteAction(
                icon = NostrVaultIcons.LinkIcon,
                label = "Copy link",
                onClick = {
                    val nevent = HavenBridge.encodeNevent(
                        note.effectiveEventId,
                        note.effectiveAuthor,
                        note.effectiveKind,
                    ) ?: HavenBridge.hexToNote1(note.effectiveEventId)
                        ?: note.effectiveEventId
                    menuClipboard.setText(AnnotatedString(threadLink(nevent)))
                    menuLane.showFeedback("Link copied", NostrVaultIcons.LinkIcon)
                },
            ),
        )
        // An article, recipe or stream opens in the web app that shows it best.
        // A repost resolved to its original carries the original's tags; one
        // that isn't has no `d` tag, so no link.
        NostrWebLinks.forEvent(note.displayKind, note.effectiveAuthor, note.tags)?.let { link ->
            add(NoteAction(NostrVaultIcons.OpenExternal, link.label) { NostrWebLinks.open(menuContext, link.url) })
        }
        // iOS lets you select the note's text in place. Here a long-press on
        // the body would fight the row's tap-to-open and the list's scroll,
        // so the text is copied whole from the menu instead.
        if (repostPlaceholder == null && note.content.isNotBlank()) {
            add(
                NoteAction(NostrVaultIcons.Copy, "Copy text") {
                    menuClipboard.setText(AnnotatedString(NostrMentions.toPlainText(note.content, profiles).trim()))
                    menuLane.showFeedback("Text copied", NostrVaultIcons.Copy)
                },
            )
        }
        onBroadcast?.let { broadcast ->
            add(NoteAction(NostrVaultIcons.Relay, "Broadcast", onClick = { broadcast(note.effectiveEventId) }))
        }
        if (isOwnNote) {
            onDelete?.let {
                add(NoteAction(NostrVaultIcons.Delete, "Delete Post", destructive = true, onClick = it))
            }
        } else {
            onReport?.let {
                add(NoteAction(NostrVaultIcons.Alert, "Report Post", destructive = true, onClick = it))
            }
            onBlock?.let {
                add(NoteAction(NostrVaultIcons.Blocked, "Block User", destructive = true, onClick = it))
            }
        }
    }
    val connectorColor = colors.primary.copy(alpha = 0.3f)
    // A holder, not state, and the bounds are worked out only on tap: no
    // per-frame work while the feed scrolls.
    val cardCoords = remember { arrayOfNulls<LayoutCoordinates>(1) }
    val zoomView = LocalView.current

    // The 🔥 rank sits above the card, clear of the time and menu (iOS
    // FeedView.feedNoteRowContent, 6pt gap).
    Column(modifier = modifier.fillMaxWidth()) {
    popularRank?.let { PopularRankLine(it) }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg.copy(alpha = 0.85f),
        // The accent outline iOS draws (FeedNoteRow.fullLayout): faint on a
        // grey card, 30% (40% on a reply) in OLED mode where the card has no
        // fill to separate it from the black; full strength when focused.
        border = BorderStroke(
            when {
                isFocused -> 2.dp
                isOled -> 1.5.dp
                note.isReply -> 0.8.dp
                else -> 0.5.dp
            },
            if (isFocused) {
                colors.primary
            } else {
                colors.primary.copy(
                    alpha = if (isOled) {
                        if (note.isReply) 0.40f else 0.30f
                    } else {
                        if (note.isReply) 0.15f else 0.06f
                    },
                )
            },
        ),
        // No shadow: 8dp of it is not legible on a near-black surface. The 2dp
        // accent border above is what says "focused".
        shadowElevation = 0.dp,
        modifier = Modifier
            .fillMaxWidth()
            .onGloballyPositioned { cardCoords[0] = it }
            .clickable {
                // The thread view zooms open out of this card (iOS #306).
                cardCoords[0]?.takeIf { it.isAttached }?.boundsInWindow()?.let { b ->
                    ThreadZoomOrigin.mark(b.center.x, b.center.y, zoomView.width, zoomView.height)
                }
                onNoteClick(note.id)
            },
    ) {
        // Subtle tint overlay matching iOS havenPurple.opacity(0.015) on focused notes
        Box(
            modifier = if (isFocused) {
                Modifier
                    .fillMaxWidth()
                    .background(colors.primary.copy(alpha = 0.04f))
            } else Modifier.fillMaxWidth(),
        ) {
        Column(
            modifier = Modifier.padding(14.dp),
        ) {
            // Parent note preview (inside card, matching iOS)
            val showParentPreview = showReplyContext && note.isReply && !parentIsNext && note.parentEventId != null
            if (showParentPreview) {
                if (parentNote != null) {
                    ParentNotePreview(
                        parentNote = parentNote,
                        parentProfile = profiles[parentNote.pubkey],
                        connectorColor = connectorColor,
                        onClick = { onNoteClick(parentNote.id) },
                        profiles = profiles,
                        avatarMenu = avatarMenu,
                        onProfileClick = onProfileClick,
                        onTrustWeb = onTrustWeb,
                    )
                } else {
                    // Skeleton for 12 s, then a failure line with Retry (iOS
                    // parentFetchFailed) rather than a skeleton that never ends.
                    val parentId = note.parentEventId
                    var parentAttempt by remember(parentId) { mutableIntStateOf(0) }
                    if (rememberPlaceholderTimedOut(parentId, parentAttempt)) {
                        ParentNoteFailed(
                            onRetry = onRetryParent?.let { retry ->
                                {
                                    parentAttempt++
                                    retry(parentId)
                                }
                            },
                        )
                    } else {
                        ParentNoteSkeleton(connectorColor = connectorColor)
                    }
                }
                Spacer(Modifier.height(10.dp))
            }

            // Repost attribution
            if (note.repostedBy != null) {
                // iOS: 10pt icon + 11pt medium text, all green at 70%,
                // indented to the name column, 10pt above the header.
                val repostTint = RepostGreen.copy(alpha = 0.7f)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(bottom = 10.dp, start = 52.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Repost,
                        contentDescription = null,
                        tint = repostTint,
                        modifier = Modifier.size(10.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "${repostedByProfile?.bestName ?: shortKey(note.repostedBy!!)} reposted",
                        color = repostTint,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            // Author header (iOS FeedNoteRow wide layout): avatar and name
            // column top-aligned, 12pt apart; the reply line sits under the
            // name inside the column.
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth(),
            ) {
                // Avatar: the quick menu in the feed, the profile elsewhere
                val authorName = profile?.bestName ?: shortKey(note.pubkey)
                AvatarWithMenu(
                    pubkey = note.pubkey,
                    displayName = authorName,
                    menu = avatarMenu,
                    onProfileClick = onProfileClick,
                    onTrustWeb = onTrustWeb,
                ) { avatarModifier ->
                    AvatarImage(
                        url = profile?.pictureURL,
                        pubkey = note.pubkey,
                        size = 40.dp,
                        displayName = profile?.bestName,
                        modifier = avatarModifier,
                    )
                }

                Spacer(Modifier.width(12.dp))

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = authorName,
                            color = PrimaryText,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            // The avatar has the menu, so the name is the way
                            // to the profile (iOS: name tap opens the profile).
                            modifier = Modifier
                                .weight(1f, fill = false)
                                .then(
                                    if (avatarMenu != null) Modifier.clickable { onProfileClick(note.pubkey) }
                                    else Modifier,
                                ),
                        )

                        // NIP-05 verification badge
                        if (!profile?.nip05.isNullOrBlank()) {
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                imageVector = NostrVaultIcons.Verified,
                                contentDescription = "Verified",
                                tint = Color(0xFF33CC99),
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

                        Spacer(Modifier.width(6.dp))
                        // iOS: a small 28x20 ellipsis at the end of the name row.
                        Box {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(width = 28.dp, height = 20.dp)
                                    .clickable { showMoreMenu = true }
                                    .semantics { contentDescription = "More" },
                            ) {
                                Icon(
                                    imageVector = NostrVaultIcons.More,
                                    contentDescription = null,
                                    tint = SecondaryText,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                            NoteActionsMenu(
                                expanded = showMoreMenu,
                                actions = moreActions,
                                onDismiss = { showMoreMenu = false },
                            )
                        }
                    }

                    // Reply indicator — subtle (iOS): purple arrow at 60%, then
                    // "reply to X" in 10pt monospace. The arrow shows even
                    // before the target is known.
                    if (note.isReply) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = NostrVaultIcons.Reply,
                                contentDescription = null,
                                tint = colors.primary.copy(alpha = 0.6f),
                                modifier = Modifier.size(10.dp),
                            )
                            note.replyToPubkey?.let { target ->
                                Spacer(Modifier.width(3.dp))
                                Text(
                                    text = "reply to ${replyToProfile?.bestName ?: shortKey(target)}",
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
                }
            }

            Spacer(Modifier.height(10.dp))

            // Content text (rich: clickable mentions, links, hashtags). Text,
            // quotes, links and media run the card's full width under the
            // avatar row, in every view (iOS #286, Logen: the most room).
            val isArticle = note.displayKind == ArticleMeta.KIND
            val poll = remember(note.id, note.displayKind, note.content) { note.poll }
            if (repostPlaceholder != null) {
                RepostPlaceholderLine(repostPlaceholder)
            } else if (isArticle) {
                // Long-form rides in the notes feed with kinds 1 and 6; its title
                // is a tag and its body Markdown, so the text path drew the whole
                // article raw and untitled. iOS ArticleInlineBody.
                ArticleInlineBody(
                    note = note,
                    onClick = {
                        // A repost's `e` tag is unchecked relay data; a value
                        // that is not an event id breaks the article route.
                        val target = note.effectiveEventId
                        if (com.nostrvault.ui.navigation.NotificationTarget.isHex64(target)) {
                            (onArticleClick ?: onNoteClick)(target)
                        }
                    },
                )
            } else if (note.displayKind == FeedHighlight.KIND) {
                HighlightInlineBody(note = note, isFocused = isFocused)
            } else if (poll != null) {
                // A NIP-88 poll's question is its content and its options are
                // tags, so the text path drew the question with nothing to
                // vote on.
                PollCard(poll = poll, isFocused = isFocused, hiddenURLs = (note.mediaURLs + note.cardLinkURLs).toSet())
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
                    onTranslationClick = { onNoteClick(note.id) },
                ) {
                    NostrContentText(
                        content = note.content,
                        profiles = profiles,
                        mediaURLs = mediaSet,
                        linkURLs = linkSet,
                        fontSize = 17.sp,
                        lineHeight = 24.sp,
                        onProfileClick = onProfileClick,
                        onPlainTextClick = { onNoteClick(note.id) },
                    )
                }
            }

            // Media thumbnails. Same order as iOS FeedNoteRow: text, media,
            // links, quotes.
            if (!isArticle && note.mediaURLs.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                MediaPreviewRow(
                    urls = note.mediaURLs,
                    tags = note.tags,
                    autoplayVideos = autoplayVideos,
                )
            }

            // One card per link. The URLs are out of the text above, so a
            // card is the only place each link still shows — quotes or not.
            // Not for an article: its links and images belong to the reader.
            if (!isArticle) for (link in note.cardLinkURLs) {
                Spacer(Modifier.height(8.dp))
                LinkPreviewCard(
                    url = link,
                )
            }

            // Quoted notes
            if (note.quotedEventIds.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                for (qid in note.quotedEventIds) {
                    val quotedNote = quotedNotes[qid]
                    if (quotedNote != null) {
                        QuotedNoteCard(
                            note = quotedNote,
                            profile = profiles[quotedNote.pubkey],
                            profiles = profiles,
                            onClick = onNoteClick,
                            onArticleClick = onArticleClick,
                        )
                    } else {
                        QuotedNotePlaceholder(
                            identifier = qid,
                            onClick = onNoteClick,
                        )
                    }
                    Spacer(Modifier.height(4.dp))
                }
            }

            Spacer(Modifier.height(8.dp))

            // Engagement bar — use effectiveEventId so that interactions
            // (reply, like, repost, zap) target the original note for kind-6
            // reposts, not the repost wrapper event.
            EngagementBar(
                noteId = note.effectiveEventId,
                isLiked = isLiked,
                isZapped = isZapped,
                isReposted = isReposted,
                onReply = onReply,
                onRepost = onRepost,
                onQuote = onQuote,
                onLike = onLike,
                onZap = onZap,
                onLongPressLike = onLongPressLike,
                onLongPressZap = onLongPressZap,
                zapDimmed = zapDimmed,
                engagement = engagement,
            )
        }
        } // Box (focused tint overlay)
    }
    } // Column (rank above the card)
}
