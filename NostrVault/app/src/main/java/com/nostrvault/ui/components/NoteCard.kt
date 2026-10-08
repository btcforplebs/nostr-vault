package com.nostrvault.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.HourglassBottom
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import coil.compose.rememberAsyncImagePainter
import coil.request.ImageRequest
import android.widget.Toast
import com.nostrvault.relay.HavenBridge
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PostEngagement
import com.nostrvault.data.model.poll
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.MediaSaveService
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.semantics.semantics
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import kotlin.math.abs
import kotlin.math.max

/**
 * What tapping an avatar offers in the feed: Follow/Unfollow, Slow down
 * (three posts a day) and Block, the iOS FeedView avatar toolbar. Without it
 * an avatar tap opens the profile, as on screens that pass none.
 */
@Stable
class AvatarMenuActions(
    /** Your own avatar opens your profile instead; there is no one to follow or block. */
    val isOwn: (String) -> Boolean,
    val isFollowed: (String) -> Boolean,
    val onFollow: (String) -> Unit,
    val onUnfollow: (String) -> Unit,
    val onSlowDown: (String) -> Unit,
    val onBlock: (String) -> Unit,
)

/** Posts a day a slowed-down account keeps, as iOS throttleUser(pubkey, 3). */
internal const val SLOW_DOWN_POSTS_PER_DAY = 3

/**
 * [content] (an avatar) that opens the [menu] for [pubkey] when tapped, or
 * the profile when there is no menu or the avatar is your own.
 */
@Composable
private fun AvatarWithMenu(
    pubkey: String,
    displayName: String,
    menu: AvatarMenuActions?,
    onProfileClick: (String) -> Unit,
    content: @Composable (Modifier) -> Unit,
) {
    if (menu == null || menu.isOwn(pubkey)) {
        content(Modifier.clickable { onProfileClick(pubkey) })
        return
    }
    var expanded by remember { mutableStateOf(false) }
    val context = LocalContext.current
    Box {
        content(Modifier.clickable(onClickLabel = "Actions for $displayName") { expanded = true })
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            val followed = menu.isFollowed(pubkey)
            DropdownMenuItem(
                text = { Text(if (followed) "Unfollow" else "Follow", color = PrimaryText) },
                leadingIcon = {
                    Icon(
                        imageVector = if (followed) Icons.Filled.PersonRemove else NostrVaultIcons.PersonAdd,
                        contentDescription = null,
                        tint = if (followed) Color(0xFFFFCC00) else SuccessGreen,
                    )
                },
                onClick = {
                    expanded = false
                    if (followed) menu.onUnfollow(pubkey) else menu.onFollow(pubkey)
                },
            )
            DropdownMenuItem(
                text = { Text("Slow down", color = PrimaryText) },
                leadingIcon = {
                    Icon(
                        imageVector = Icons.Filled.HourglassBottom,
                        contentDescription = null,
                        tint = ZapOrange,
                    )
                },
                onClick = {
                    expanded = false
                    menu.onSlowDown(pubkey)
                    Toast.makeText(context, "Slowed down $displayName", Toast.LENGTH_SHORT).show()
                },
            )
            DropdownMenuItem(
                text = { Text("Block", color = ErrorRed) },
                leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = ErrorRed) },
                onClick = {
                    expanded = false
                    menu.onBlock(pubkey)
                    Toast.makeText(context, "Blocked $displayName", Toast.LENGTH_SHORT).show()
                },
            )
        }
    }
}

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
    parentIsNext: Boolean = false,
    hasReplyBelow: Boolean = false,
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
    /** With it, an avatar tap opens Follow / Slow down / Block, and the name opens the profile. */
    avatarMenu: AvatarMenuActions? = null,
    /**
     * Likes, reposts, replies, quotes and zap sats, where the screen fetched
     * them (profiles, [com.nostrvault.service.ProfileEngagementStore]). Each
     * number goes on its own button; null leaves the buttons bare.
     */
    engagement: PostEngagement? = null,
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
                    Toast.makeText(menuContext, "Link copied", Toast.LENGTH_SHORT).show()
                },
            ),
        )
        // iOS lets you select the note's text in place. Here a long-press on
        // the body would fight the row's tap-to-open and the list's scroll,
        // so the text is copied whole from the menu instead.
        if (repostPlaceholder == null && note.content.isNotBlank()) {
            add(
                NoteAction(NostrVaultIcons.Copy, "Copy text") {
                    menuClipboard.setText(AnnotatedString(NostrMentions.toPlainText(note.content, profiles).trim()))
                    Toast.makeText(menuContext, "Text copied", Toast.LENGTH_SHORT).show()
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

    // Thread connector lines drawn behind the card
    val drawConnectors = parentIsNext || hasReplyBelow
    val connectorModifier = if (drawConnectors) {
        // Avatar center X = 14dp padding + 20dp (half avatar) = 34dp
        // Avatar center Y = 14dp padding + repost row height (if any) + 20dp (half avatar)
        Modifier.drawBehind {
            val lineX = 34.dp.toPx()
            val lineWidth = 2.dp.toPx()
            val avatarTop = 14.dp.toPx() + if (note.repostedBy != null) 24.dp.toPx() else 0f
            val avatarCenter = avatarTop + 20.dp.toPx()

            // Line from card top down to avatar center (connects to card above)
            if (parentIsNext) {
                drawLine(
                    color = connectorColor,
                    start = Offset(lineX, 0f),
                    end = Offset(lineX, avatarCenter),
                    strokeWidth = lineWidth,
                )
            }
            // Line from avatar bottom down to card bottom (connects to card below)
            if (hasReplyBelow) {
                drawLine(
                    color = connectorColor,
                    start = Offset(lineX, avatarCenter),
                    end = Offset(lineX, size.height),
                    strokeWidth = lineWidth,
                )
            }
        }
    } else {
        Modifier
    }

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
        modifier = modifier
            .fillMaxWidth()
            .then(connectorModifier)
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
                // Connector stub bridging parent preview to current note's avatar
                Box(
                    modifier = Modifier
                        .padding(start = 19.dp) // center of 40dp avatar - 1dp half width
                        .width(2.dp)
                        .height(8.dp)
                        .background(connectorColor),
                )
            }

            // Repost attribution
            if (note.repostedBy != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(bottom = 6.dp, start = 40.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Repost,
                        contentDescription = null,
                        tint = RepostGreen,
                        modifier = Modifier.size(12.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "${repostedByProfile?.bestName ?: note.repostedBy!!.take(8) + "..."} reposted",
                        color = SecondaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            // Author header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                // Avatar: the quick menu in the feed, the profile elsewhere
                val authorName = profile?.bestName ?: note.pubkey.take(8) + "..."
                AvatarWithMenu(
                    pubkey = note.pubkey,
                    displayName = authorName,
                    menu = avatarMenu,
                    onProfileClick = onProfileClick,
                ) { avatarModifier ->
                    AvatarImage(
                        url = profile?.pictureURL,
                        pubkey = note.pubkey,
                        size = 40.dp,
                        displayName = profile?.bestName,
                        modifier = avatarModifier,
                    )
                }

                Spacer(Modifier.width(10.dp))

                Column(modifier = Modifier.weight(1f)) {
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
                            Spacer(Modifier.width(4.dp))
                            Icon(
                                imageVector = NostrVaultIcons.Verified,
                                contentDescription = "Verified",
                                tint = Color(0xFF33CC99),
                                modifier = Modifier.size(14.dp),
                            )
                        }
                        if (note.isFromNostrVault) {
                            Spacer(Modifier.width(4.dp))
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
                }

                // More menu
                Box {
                    IconButton(onClick = { showMoreMenu = true }) {
                        Icon(
                            imageVector = NostrVaultIcons.More,
                            contentDescription = "More",
                            tint = SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    NoteActionsMenu(
                        expanded = showMoreMenu,
                        actions = moreActions,
                        onDismiss = { showMoreMenu = false },
                    )
                }
            }

            // Reply indicator
            if (note.isReply && note.replyToPubkey != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(top = 4.dp, start = 50.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Reply,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(12.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "replying to ${replyToProfile?.bestName ?: note.replyToPubkey!!.take(8) + "..."}",
                        color = SecondaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

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
                    onClick = { (onArticleClick ?: onNoteClick)(note.effectiveEventId) },
                )
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

            // One card per link. The URLs are out of the text above, so a
            // card is the only place each link still shows — quotes or not.
            // Not for an article: its links and images belong to the reader.
            if (!isArticle) for (link in note.cardLinkURLs) {
                Spacer(Modifier.height(8.dp))
                LinkPreviewCard(
                    url = link,
                )
            }

            // Media thumbnails
            if (!isArticle && note.mediaURLs.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                MediaPreviewRow(
                    urls = note.mediaURLs,
                    tags = note.tags,
                    autoplayVideos = autoplayVideos,
                )
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
}

/**
 * A kind-30023 article inside a feed row: cover, title, "Article · N min
 * read", and the summary (or the top of the body, Markdown stripped). Tapping
 * opens the reader. The row above already draws the author and the time, so
 * this is not the Articles feed's own card. iOS ArticleInlineBody.
 */
@Composable
private fun ArticleInlineBody(
    note: FeedNote,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val preview = remember(note.id) { ArticleMeta.previewText(meta.summary, note.content) }
    val minutes = remember(note.id) { ArticleMeta.readingTimeMinutes(note.content) }
    val accent = LocalNostrVaultColors.current.primary
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClickLabel = "Read article", onClick = onClick),
    ) {
        meta.imageUrl?.let { url ->
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current)
                    .data(url)
                    .size(800)
                    .crossfade(100)
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(140.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(TertiaryGroupedBg),
            )
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 23.sp,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = NostrVaultIcons.Articles,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(11.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = if (minutes != null) "Article · $minutes min read" else "Article",
                color = accent,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        preview?.let {
            Text(
                text = it,
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 20.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Action button row. Mirrors the iOS feed note layout: capsule-background
 * icon buttons, left-aligned with fixed spacing, with a spring scale-up on
 * active states.
 * Order: Reply → Repost → Quote → Like → Zap.
 *
 * Counts only where the screen fetched [engagement] (profiles), as on iOS:
 * each button carries its own number ("Reply 5", "Like 64+"), zero shows
 * none. Elsewhere the numbers belong to the thread view, which shows them as
 * its own row (ThreadNoteEngagementRow, the hero note's stats).
 *
 * **Five buttons, with Share and Broadcast in the ⋯ menu.** iOS put them in
 * the row and had no ⋯ menu, so a note there could not be reported, blocked
 * or copied; both apps now use this row plus the menu. Share sits next to
 * Copy link there, where it belongs.
 *
 * **Every child is unweighted, deliberately.** An equal `weight(1f)` hands each
 * cell the same width whether it needs 32dp or 58dp, and inside a counted cell
 * the count is the last child measured — so the shortfall lands on it and it is
 * clipped to a sliver of one glyph, silently, with a green build. Unweighted,
 * a cell measures at what it needs, the slack stays at the end of the row, and
 * a genuine overflow drops a whole button where you can see it.
 *
 * `spacedBy` rather than `SpaceBetween` for the same reason it is not weighted:
 * nothing in this app caps the content width (no `widthIn`, no
 * `WindowSizeClass`, no `sw600dp` resources, no `screenOrientation` lock), so a
 * landscape phone is one ~800dp column and an elastic spread would put ~140dp
 * of air between buttons. The child count is also runtime-variable — Quote is
 * gated on its handler, Like disappears under Zaps Only — so the gaps would
 * differ between two notes in the same scroll.
 *
 * Every button is gated on its own handler. Quote already was; the rest
 * rendered at full opacity, took the tap and ran the pulse into
 * `handler?.invoke(...)`. On a screen that passes no handlers — search
 * results — that is a row of buttons animating a confirmation for an event
 * nobody signed. One rule now: no handler, no affordance.
 */
@Composable
internal fun EngagementBar(
    noteId: String,
    isLiked: Boolean,
    isZapped: Boolean,
    isReposted: Boolean = false,
    onReply: ((String) -> Unit)?,
    onRepost: ((String) -> Unit)?,
    onQuote: ((String) -> Unit)?,
    onLike: ((String) -> Unit)?,
    onZap: ((String) -> Unit)?,
    onLongPressLike: ((String) -> Unit)? = null,
    onLongPressZap: ((String) -> Unit)? = null,
    zapDimmed: Boolean = false,
    engagement: PostEngagement? = null,
    modifier: Modifier = Modifier,
) {
    fun label(value: Long) = engagement?.let { postEngagementLabel(value, it.isAtLeast(value)) }
    fun spoken(value: Long, noun: String) =
        engagement?.let { postEngagementDescription(value, noun, it.isAtLeast(value)) }
    // No spacing here: each button carries its own 4dp a side inside its tap
    // target, so the drawn gap is still 8dp and the pitch is still 40dp, with
    // no dead strip between two targets. See [EngagementButton].
    // Five counted buttons do not always fit a 360dp phone ("12+", "2.1k+"…),
    // so a row with profile counts scrolls rather than clipping Zap.
    val counted = engagement != null
    Row(
        horizontalArrangement = Arrangement.spacedBy(0.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .then(if (counted) Modifier.horizontalScroll(rememberScrollState()) else Modifier),
    ) {
        // Reply
        if (onReply != null) {
            EngagementButton(
                icon = NostrVaultIcons.ReplyAction,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Reply",
                onClick = { onReply.invoke(noteId) },
                count = engagement?.let { label(it.replies.toLong()) },
                countDescription = engagement?.let { spoken(it.replies.toLong(), "replies") },
            )
        }

        // Repost
        if (onRepost != null) {
            EngagementButton(
                icon = NostrVaultIcons.Repost,
                isActive = isReposted,
                activeColor = RepostGreen,
                contentDescription = if (isReposted) "Reposted" else "Repost",
                onClick = { onRepost.invoke(noteId) },
                count = engagement?.let { label(it.reposts.toLong()) },
                countDescription = engagement?.let { spoken(it.reposts.toLong(), "reposts") },
            )
        }

        // Quote
        if (onQuote != null) {
            EngagementButton(
                icon = NostrVaultIcons.Quote,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Quote",
                onClick = { onQuote.invoke(noteId) },
                count = engagement?.let { label(it.quotes.toLong()) },
                countDescription = engagement?.let { spoken(it.quotes.toLong(), "quotes") },
            )
        }

        // Like: tap reacts or takes it back, hold opens the tapback bar
        // (its "+" is the emoji picker). Hidden entirely in Zaps Only mode.
        if (onLike != null && !LocalZapsOnlyMode.current) {
            ReactionButton(
                noteId = noteId,
                isLiked = isLiked,
                onTap = { onLike.invoke(noteId) },
                onMore = onLongPressLike?.let { more -> { more(noteId) } },
                count = engagement?.let { label(it.likes.toLong()) },
                countDescription = engagement?.let { spoken(it.likes.toLong(), "likes") },
            )
        }

        // Zap
        if (onZap != null) Box(Modifier.zapFlightTarget(noteId)) {
            EngagementButton(
                icon = if (isZapped) NostrVaultIcons.Zap else NostrVaultIcons.ZapOutline,
                isActive = isZapped,
                activeColor = ZapOrange,
                contentDescription = if (isZapped) "Zapped" else "Zap",
                onClick = { onZap.invoke(noteId) },
                onLongClick = onLongPressZap?.let { longPress -> { longPress(noteId) } },
                dimmed = zapDimmed && !isZapped,
                count = engagement?.let { label(it.zapSats) },
                countDescription = engagement?.let { spoken(it.zapSats, "sats zapped") },
            )
        }

        // Slack stays here, at the end, rather than being spread between the
        // buttons — see the arrangement note above. A scrolling row has no
        // slack to hold.
        if (!counted) Spacer(Modifier.weight(1f))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun EngagementButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isActive: Boolean,
    activeColor: androidx.compose.ui.graphics.Color,
    contentDescription: String?,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    count: String? = null,
    /** [count] as TalkBack reads it ("at least 64 likes"). */
    countDescription: String? = null,
    /** Drawn faint and without the tap pulse: the tap explains why it can't act. */
    dimmed: Boolean = false,
) {
    val tint = if (isActive) activeColor else if (dimmed) SecondaryText.copy(alpha = 0.35f) else SecondaryText
    val background = if (isActive) {
        activeColor.copy(alpha = 0.18f)
    } else {
        SecondaryText.copy(alpha = 0.10f)
    }
    // The pulse fires on the *tap*, not on `isActive`.
    //
    // Bound to state, it replayed on every reaction that arrived from backfill
    // or from another client — icons bouncing unprompted down a scrolling feed.
    // iOS routes this through `Motion.firePulse` for exactly that reason: the
    // caller owns the tap, not the resulting state. The tint and background
    // below still track `isActive`, because those carry the *meaning* and should
    // update however the state arrived.
    //
    // Numbers come from the shared token now: 1.12 rather than the 1.2 this
    // had, and damping 0.62 rather than 0.45 — the old inline comment was
    // citing an iOS spec that has since been retired.
    var pulsing by remember { mutableStateOf(false) }
    LaunchedEffect(pulsing) {
        if (pulsing) {
            delay(Motion.PULSE_HOLD_MS)
            pulsing = false
        }
    }
    val scale by animateFloatAsState(
        targetValue = if (pulsing) Motion.PULSE_SCALE else 1f,
        animationSpec = Motion.pop(),
        label = "engagementScale",
    )

    // No pulse at all under Reduce Motion, matching `Motion.firePulse`'s early
    // return — the icon's fill and colour already carry the confirmation.
    //
    // Only the tap pulses. A long press opens a picker sheet rather than
    // publishing anything, so there is no signed event for the bounce to be
    // confirming.
    val tapAndPulse = {
        if (!Motion.isReduced && !dimmed) pulsing = true
        onClick()
    }

    // The tap target is the outer node, not the capsule. The capsule is 32dp and
    // stays 32dp — this is the shape the row was measured around (see
    // [EngagementBar]) — but Material's minimum touch target is 48dp and a
    // 32dp one on a row of seven, with Zap and Repost one tap from a real
    // consequence, is where mis-taps get expensive.
    //
    // Vertically that is free: 48dp of height costs the card 16dp and nothing
    // else, so the target is a full 48dp tall.
    //
    // Horizontally it is not free, and 48dp wide does not fit. The row has
    // 312dp on a 360dp phone; three counted capsules at their widest label
    // ("999k", "9.9M" — `formatCount` never exceeds four glyphs) plus two
    // 32dp circles plus the gaps is 282dp, and taking each circle to 48dp
    // costs 32dp more than the 30dp left. So the target takes the *gap*
    // instead: the 8dp between buttons moves inside the clickable node, 4dp a
    // side, which leaves the drawn spacing at 8dp and the pitch at 40dp
    // exactly as before while removing the dead strip between two targets.
    // 40x48 contiguous, rather than 32x32 with 8dp of nothing around it.
    //
    // `indication` has to be stated because the clickable is now outside the
    // clip: bounded, it would ripple the whole 40x48 rect instead of the
    // capsule. An unbounded 20dp radius draws the same 40dp state layer
    // Material's own `IconButton` uses.
    val interactionSource = remember { MutableInteractionSource() }
    val indication = ripple(bounded = false, radius = 20.dp)
    val clickModifier = if (onLongClick != null) {
        Modifier.combinedClickable(
            interactionSource = interactionSource,
            indication = indication,
            onClick = tapAndPulse,
            onLongClick = onLongClick,
        )
    } else {
        Modifier.clickable(
            interactionSource = interactionSource,
            indication = indication,
            onClick = tapAndPulse,
        )
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .scale(scale)
            .height(48.dp)
            .then(clickModifier)
            .padding(horizontal = 4.dp),
    ) {
    // With a count the button becomes a capsule wide enough for the number; with
    // none it stays the 32dp circle it has always been. Height is fixed at 32dp
    // either way so a row of mixed buttons does not step up and down as counts
    // arrive from backfill.
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .height(32.dp)
            .then(if (count == null) Modifier.width(32.dp) else Modifier.widthIn(min = 32.dp))
            .clip(CircleShape)
            .background(background)
            .then(if (count == null) Modifier else Modifier.padding(horizontal = 9.dp)),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = tint,
            modifier = Modifier.size(16.dp),
        )
        if (count != null) {
            Spacer(Modifier.width(4.dp))
            Text(
                text = count,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = tint,
                maxLines = 1,
                modifier = if (countDescription == null) Modifier
                else Modifier.semantics { this.contentDescription = countDescription },
            )
        }
    }
    }
}

private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "webm", "avi", "mkv", "m4v")

internal fun isVideoUrl(url: String): Boolean {
    val ext = url.substringAfterLast('.').substringBefore('?').lowercase()
    return ext in VIDEO_EXTENSIONS
}

private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "wav", "ogg", "aac", "flac", "opus")

/** An audio file: it plays from a card, not in the photo/video viewer. */
internal fun isAudioUrl(url: String): Boolean {
    val ext = url.substringAfterLast('.').substringBefore('?').substringBefore('#').lowercase()
    return ext in AUDIO_EXTENSIONS
}

@Composable
fun MediaPreviewRow(
    urls: List<String>,
    /** The note's tags, read for NIP-92 `imeta dim` so the box is right first time. */
    tags: List<List<String>> = emptyList(),
    /** Play videos inline (muted, looping, one at a time) instead of a poster. */
    autoplayVideos: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // Audio plays from its own card on the app-wide player; the rest open
    // the viewer. iOS: FeedAudioCard.
    val (audio, visual) = remember(urls) { urls.partition(::isAudioUrl) }
    if (audio.isEmpty()) {
        VisualMediaPreview(visual, tags, autoplayVideos, modifier)
        return
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (visual.isNotEmpty()) VisualMediaPreview(visual, tags, autoplayVideos)
        audio.forEach { com.nostrvault.ui.screens.music.AudioFileCard(it) }
    }
}

@Composable
private fun VisualMediaPreview(
    urls: List<String>,
    tags: List<List<String>>,
    autoplay: Boolean,
    modifier: Modifier = Modifier,
) {
    // One id per row, so the viewer can find the photo it opened from.
    val origin = remember { MediaZoomSources.newOrigin() }
    if (urls.size == 1) {
        SingleMediaPreview(
            url = urls.first(),
            tags = tags,
            sourceKey = MediaSourceKey(origin, 0),
            onMediaClick = { FullScreenMediaRouter.open(urls, 0, origin) },
            autoplay = autoplay,
            modifier = modifier,
        )
    } else {
        MediaCarousel(
            urls = urls,
            tags = tags,
            origin = origin,
            onMediaClick = { index -> FullScreenMediaRouter.open(urls, index, origin) },
            autoplay = autoplay,
            modifier = modifier,
        )
    }
}

/**
 * Full-screen, swipeable viewer for a note's media. Opens at the tapped item and
 * pages horizontally across the note's images/videos, with pinch-to-zoom and
 * vertical drag-to-dismiss (matching the dedicated gallery viewer / iOS). Keeps
 * the lightweight mirror pill + close affordances of the old single-item dialog;
 * the mirror pill tracks whichever page is currently visible.
 *
 * Rendered as an activity-window overlay via [FullScreenMediaHost] — NOT a Dialog —
 * so Picture-in-Picture (which only captures the activity's own window) can show
 * the playing video. All chrome hides while the activity is in PiP.
 *
 * With an [origin], a photo zooms out of its spot in the feed and, on close
 * (swipe, back, or the X), back into it — iOS #117. It fades instead for a
 * video, a zoomed-in photo, a spot that has scrolled away, or Reduce Motion.
 * [onDismiss] runs once the close animation has landed.
 *
 * Audio pages play in [AudioPlayer], as iOS's MediaItemRenderer does; a
 * vertical drag closes video and audio pages as it does a photo. [copyLink]
 * adds a Copy link button (the profile viewer's, iOS ProfileView).
 */
@Composable
internal fun FullScreenMediaPager(
    urls: List<String>,
    initialIndex: Int,
    onDismiss: () -> Unit,
    origin: Long? = null,
    copyLink: Boolean = false,
    viewModel: FeedMediaMirrorViewModel = hiltViewModel(),
) {
    val mirrorState by viewModel.state.collectAsState()
    val saveState by viewModel.saveState.collectAsState()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val isInPiP by VideoPiPBridge.isInPiP.collectAsState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    val pagerState = rememberPagerState(
        initialPage = initialIndex.coerceIn(0, urls.lastIndex),
        pageCount = { urls.size },
    )
    val currentUrl = urls[pagerState.currentPage]

    // Re-evaluate mirror status whenever the visible page changes (the ViewModel is
    // shared across the feed, so only one viewer is ever active).
    LaunchedEffect(currentUrl) { viewModel.onOpen(currentUrl) }
    LaunchedEffect(pagerState.currentPage) { FullScreenMediaRouter.setPage(pagerState.currentPage) }

    // Drag-to-dismiss state, using the same visual formulas as MediaViewerScreen / iOS.
    val dragOffsetY = remember { Animatable(0f) }
    var currentScale by remember { mutableFloatStateOf(1f) }
    var accumulatedDragY by remember { mutableFloatStateOf(0f) }
    val dismissThresholdPx = with(density) { 120.dp.toPx() }

    val backgroundAlpha by remember {
        derivedStateOf { (1f - abs(dragOffsetY.value) / 300f).coerceIn(0f, 1f) }
    }
    val contentScale by remember {
        derivedStateOf { max(0.8f, 1f - abs(dragOffsetY.value) / 1000f) }
    }
    val overlayAlpha by remember {
        derivedStateOf { (1f - abs(dragOffsetY.value) / 100f).coerceIn(0f, 1f) }
    }

    // ── Zoom in from / out to the tapped photo ──────────────────────────
    // 0 = drawn over the source (or invisible, for a fade), 1 = full screen.
    val progress = remember { Animatable(0f) }
    // The transform at progress 0; null means cross-fade.
    var zoomFrom by remember { mutableStateOf<ZoomTransform?>(null) }
    var sourceRect by remember { mutableStateOf<ZoomRect?>(null) }
    var containerOrigin by remember { mutableStateOf(Offset.Zero) }
    var containerSize by remember { mutableStateOf(IntSize.Zero) }
    var closing by remember { mutableStateOf(false) }

    /** The zoom for the item at [page], or null when it should fade. */
    fun zoomFor(page: Int): Pair<ZoomTransform, ZoomRect>? {
        if (origin == null || Motion.isReduced || containerSize == IntSize.Zero) return null
        val url = urls.getOrNull(page) ?: return null
        if (isVideoUrl(url) || isAudioUrl(url)) return null
        val source = MediaZoomSources.get(MediaSourceKey(origin, page)) ?: return null
        if (!MediaZoomGeometry.isOnScreen(source.full, source.visible)) return null
        val rect = source.full.offset(-containerOrigin.x, -containerOrigin.y)
        val w = containerSize.width.toFloat()
        val h = containerSize.height.toFloat()
        // The viewer draws the image Fit; without a known ratio the source
        // box's own shape is the best guess (exact for a feed card).
        val aspect = MediaAspectCache.get(url) ?: (rect.width / rect.height)
        val fitted = MediaZoomGeometry.fit(aspect, w, h)
        return MediaZoomGeometry.transform(fitted, rect, source.crop) to rect
    }

    // Keyed on "laid out yet", not the size, so a rotation mid-zoom doesn't cancel it.
    val laidOut = containerSize != IntSize.Zero
    LaunchedEffect(laidOut) {
        if (!laidOut || closing || progress.value > 0f) return@LaunchedEffect
        val zoom = zoomFor(pagerState.currentPage)
        zoomFrom = zoom?.first
        sourceRect = zoom?.second
        if (zoom != null && origin != null) {
            FullScreenMediaRouter.setHiddenSource(MediaSourceKey(origin, pagerState.currentPage))
        }
        progress.animateTo(1f, if (zoom != null) Motion.panel() else Motion.fade())
        // Once full screen the black covers the source; show it again so a page
        // change can't leave a hole in the carousel underneath.
        FullScreenMediaRouter.setHiddenSource(null)
    }

    val close: () -> Unit = close@{
        if (closing) return@close
        closing = true
        val page = pagerState.currentPage
        val zoom = if (currentScale <= 1.05f) zoomFor(page) else null
        zoomFrom = zoom?.first
        sourceRect = zoom?.second
        if (zoom != null && origin != null) {
            FullScreenMediaRouter.setHiddenSource(MediaSourceKey(origin, page))
        }
        scope.launch {
            launch { dragOffsetY.animateTo(0f, if (zoom != null) Motion.panel() else Motion.fade()) }
            progress.animateTo(0f, if (zoom != null) Motion.panel() else Motion.fade())
            onDismiss()
        }
    }

    BackHandler(onBack = close)

    // Drag-to-dismiss, fed by ZoomableImage on a photo and by a drag detector
    // on a video or audio page.
    val onVerticalDrag: (Float) -> Unit = { deltaY ->
        if (currentScale <= 1.05f && !closing) {
            accumulatedDragY += deltaY
            scope.launch { dragOffsetY.snapTo(accumulatedDragY) }
        }
    }
    val onVerticalDragEnd: () -> Unit = {
        if (closing) {
            // The close animation owns the offset now.
        } else if (abs(accumulatedDragY) > dismissThresholdPx) {
            close()
        } else {
            scope.launch {
                dragOffsetY.animateTo(0f, Motion.snapBack())
            }
        }
        accumulatedDragY = 0f
    }

    val shown by remember { derivedStateOf { progress.value.coerceIn(0f, 1f) } }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned {
                containerOrigin = it.positionInWindow()
                containerSize = it.size
            }
            .background(Color.Black.copy(alpha = backgroundAlpha * shown))
            // Swallow taps that no child consumed so they can't reach the UI beneath
            .pointerInput(Unit) { detectTapGestures { } },
    ) {
            HorizontalPager(
                state = pagerState,
                // Lock paging while a page is zoomed so pan doesn't flip pages.
                userScrollEnabled = currentScale <= 1.05f && !closing,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val from = zoomFrom
                        if (from == null) {
                            alpha = shown
                        } else {
                            val t = MediaZoomGeometry.interpolate(from, progress.value)
                            transformOrigin = TransformOrigin(0f, 0f)
                            scaleX = t.scale
                            scaleY = t.scale
                            translationX = t.translationX
                            translationY = t.translationY
                        }
                    }
                    .drawWithContent {
                        val from = zoomFrom
                        val src = sourceRect
                        if (from == null || src == null || progress.value >= 1f) {
                            drawContent()
                        } else {
                            // Clip to the source's shape at 0, opening to the full screen.
                            val clip = MediaZoomGeometry.lerpRect(
                                MediaZoomGeometry.toLocal(src, from),
                                ZoomRect(0f, 0f, size.width, size.height),
                                progress.value,
                            )
                            clipRect(clip.left, clip.top, clip.left + clip.width, clip.top + clip.height) {
                                this@drawWithContent.drawContent()
                            }
                        }
                    }
                    .graphicsLayer {
                        translationY = dragOffsetY.value
                        scaleX = contentScale
                        scaleY = contentScale
                    },
            ) { page ->
                val url = urls[page]
                if (isVideoUrl(url) || isAudioUrl(url)) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(Color.Black)
                            .pointerInput(Unit) {
                                detectVerticalDragGestures(
                                    onDragEnd = onVerticalDragEnd,
                                    onDragCancel = onVerticalDragEnd,
                                ) { change, dragAmount ->
                                    change.consume()
                                    onVerticalDrag(dragAmount)
                                }
                            },
                    ) {
                        // Only the visible page gets a player, to keep memory at one instance.
                        if (page == pagerState.currentPage) {
                            if (isAudioUrl(url)) {
                                AudioPlayer(
                                    uri = url,
                                    fileName = url.substringAfterLast('/').substringBefore('?').substringBefore('#'),
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else {
                                VideoPlayer(uri = url, modifier = Modifier.fillMaxSize())
                            }
                        }
                    }
                } else {
                    ZoomableImage(
                        model = url,
                        contentDescription = null,
                        onScaleChanged = { currentScale = it },
                        onVerticalDrag = onVerticalDrag,
                        onVerticalDragEnd = { onVerticalDragEnd() },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            if (!isInPiP) {
                IconButton(
                    onClick = close,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .statusBarsPadding()
                        .padding(8.dp)
                        .size(40.dp)
                        .graphicsLayer { alpha = overlayAlpha * shown }
                        .background(Color.Black.copy(alpha = 0.4f), CircleShape),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Dismiss,
                        contentDescription = "Close",
                        tint = Color.White,
                    )
                }
            }

            // Top row, like iOS (PR #120): Save, then Mirror / Mirrored, one-word
            // labels. Messages go out as system toasts: the in-app pills draw
            // under this overlay.
            if (!isInPiP) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(8.dp)
                        .graphicsLayer { alpha = overlayAlpha * shown },
                ) {
                    if (copyLink && isShareableMediaUrl(currentUrl)) {
                        IconButton(
                            onClick = {
                                clipboard.setText(AnnotatedString(currentUrl))
                                Toast.makeText(context, "Link copied", Toast.LENGTH_SHORT).show()
                            },
                            modifier = Modifier
                                .size(36.dp)
                                .background(Color.Black.copy(alpha = 0.6f), CircleShape),
                        ) {
                            Icon(NostrVaultIcons.Copy, "Copy link", tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                    }
                    // A photo or video, as iOS offers Save to Photos; not audio.
                    if (!isAudioUrl(currentUrl)) {
                        SaveToGalleryPill(
                            state = saveState,
                            onSave = {
                                viewModel.saveToGallery(currentUrl) { message ->
                                    Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
                                }
                            },
                        )
                    }
                    if (viewModel.canMirror) {
                        MirrorToBlossomPill(
                            state = mirrorState,
                            onMirror = { viewModel.mirror(currentUrl) },
                        )
                    }
                }
            }

            // Page-position bar, only when the note carries more than one item.
            if (urls.size > 1 && !isInPiP) {
                PagePositionBar(
                    count = urls.size,
                    index = pagerState.currentPage,
                    track = Color.White.copy(alpha = 0.35f),
                    lit = Color.White,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 24.dp)
                        .graphicsLayer { alpha = overlayAlpha * shown },
                )
            }
    }
}

/** Capsule button / status indicator that backs up the viewed media to the local Blossom store. */
@Composable
private fun MirrorToBlossomPill(
    state: FeedMediaMirrorViewModel.MirrorState,
    onMirror: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bg = when (state) {
        FeedMediaMirrorViewModel.MirrorState.Mirrored -> Color(0xFF33CC99).copy(alpha = 0.85f)
        is FeedMediaMirrorViewModel.MirrorState.Failed -> Color(0xFFE53935).copy(alpha = 0.85f)
        else -> Color.Black.copy(alpha = 0.6f)
    }

    // Tapping does nothing while in progress or already mirrored; Idle/Failed trigger a (re)mirror.
    val clickable = state is FeedMediaMirrorViewModel.MirrorState.Idle ||
        state is FeedMediaMirrorViewModel.MirrorState.Failed

    val spoken = when (state) {
        FeedMediaMirrorViewModel.MirrorState.Mirroring -> "Mirroring to Blossom"
        FeedMediaMirrorViewModel.MirrorState.Mirrored -> "Mirrored to Blossom"
        is FeedMediaMirrorViewModel.MirrorState.Failed -> "Mirror failed, retry"
        FeedMediaMirrorViewModel.MirrorState.Idle -> "Mirror to Blossom"
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .then(if (clickable) Modifier.clickable(onClick = onMirror) else Modifier)
            .semantics(mergeDescendants = true) { contentDescription = spoken }
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        when (state) {
            FeedMediaMirrorViewModel.MirrorState.Mirroring -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = Color.White,
                    strokeWidth = 2.dp,
                )
                Spacer(Modifier.width(6.dp))
                Text("Mirroring…", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            FeedMediaMirrorViewModel.MirrorState.Mirrored -> {
                Icon(NostrVaultIcons.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Mirrored", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            is FeedMediaMirrorViewModel.MirrorState.Failed -> {
                Icon(NostrVaultIcons.Dismiss, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Retry", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            FeedMediaMirrorViewModel.MirrorState.Idle -> {
                Icon(NostrVaultIcons.Backup, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Mirror", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/** Capsule that saves the viewed photo or video to the device gallery. */
@Composable
private fun SaveToGalleryPill(
    state: FeedMediaMirrorViewModel.SaveState,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val saved = state == FeedMediaMirrorViewModel.SaveState.Saved
    val bg = if (saved) Color(0xFF33CC99).copy(alpha = 0.85f) else Color.Black.copy(alpha = 0.6f)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .then(
                if (state == FeedMediaMirrorViewModel.SaveState.Idle) Modifier.clickable(onClick = onSave)
                else Modifier,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = if (saved) "Saved to gallery" else "Save to gallery"
            }
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        if (state == FeedMediaMirrorViewModel.SaveState.Saving) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                color = Color.White,
                strokeWidth = 2.dp,
            )
        } else {
            Icon(
                imageVector = if (saved) NostrVaultIcons.Check else NostrVaultIcons.Import,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(16.dp),
            )
        }
        Spacer(Modifier.width(6.dp))
        Text(
            text = when (state) {
                FeedMediaMirrorViewModel.SaveState.Saving -> "Saving…"
                FeedMediaMirrorViewModel.SaveState.Saved -> "Saved"
                FeedMediaMirrorViewModel.SaveState.Idle -> "Save"
            },
            color = Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}

@HiltViewModel
class FeedMediaMirrorViewModel @Inject constructor(
    private val blossomService: BlossomService,
    private val mediaCacheService: MediaCacheService,
    private val mediaSaveService: MediaSaveService,
) : ViewModel() {

    enum class SaveState { Idle, Saving, Saved }

    private val _saveState = MutableStateFlow(SaveState.Idle)
    val saveState = _saveState.asStateFlow()

    /** The URL on screen; a save that finishes after the user paged away leaves the new page's state alone. */
    private var openUrl: String? = null

    /**
     * Save the media on screen to the device gallery (MediaStore, no storage
     * permission on Android 10+). [onMessage] gets one short line for a toast.
     * Port of iOS FeedMediaViewer.saveToPhotosTapped().
     */
    fun saveToGallery(url: String, onMessage: (String) -> Unit) {
        if (_saveState.value != SaveState.Idle) return
        viewModelScope.launch {
            _saveState.value = SaveState.Saving
            // Feed videos are recognised by extension, so that names the type
            // when the server only says application/octet-stream.
            val hint = if (isVideoUrl(url)) MediaSaveService.mimeTypeForExtension(url) else null
            val result = mediaSaveService.saveToGallery(url, hint)
            if (openUrl == url) {
                _saveState.value = if (result.isSuccess) SaveState.Saved else SaveState.Idle
            }
            onMessage(if (result.isSuccess) "Saved to gallery" else "Couldn't save to gallery")
        }
    }

    sealed interface MirrorState {
        data object Idle : MirrorState
        data object Mirroring : MirrorState
        data object Mirrored : MirrorState
        data class Failed(val message: String) : MirrorState
    }

    private val _state = MutableStateFlow<MirrorState>(MirrorState.Idle)
    val state = _state.asStateFlow()

    /** False when there's no local relay to back media up to — hides the button entirely. */
    val canMirror: Boolean get() = blossomService.localBlossomURL() != null

    /**
     * Called when a media URL is opened in the viewer. If the URL is hash-based and
     * the blob is already in the local Blossom store, start in the "Mirrored" state;
     * otherwise offer the mirror action. Mirrors iOS FeedMediaViewer.updateMirrorStatus().
     */
    fun onOpen(url: String) {
        openUrl = url
        _saveState.value = SaveState.Idle
        val hash = extractSha256(url)
        _state.value = if (hash != null && mediaCacheService.isInLocalBlossom(hash)) {
            MirrorState.Mirrored
        } else {
            MirrorState.Idle
        }
    }

    fun mirror(url: String) {
        if (_state.value is MirrorState.Mirroring) return
        viewModelScope.launch {
            _state.value = MirrorState.Mirroring
            val sha = withContext(Dispatchers.IO) { blossomService.mirrorUrlToLocal(url) }
            _state.value = if (sha != null) MirrorState.Mirrored else MirrorState.Failed("Mirror failed")
        }
    }

    /** Extract a 64-hex sha256 from a Blossom-style URL, or null. Mirrors iOS extractSHA256FromURL(). */
    private fun extractSha256(url: String): String? {
        val last = url.substringAfterLast('/').substringBefore('?').substringBefore('#')
        val bare = last.substringBeforeLast('.')
        if (bare.length == 64 && bare.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) {
            return bare.lowercase()
        }
        return Regex("[a-fA-F0-9]{64}").find(url)?.value?.lowercase()
    }
}

@Composable
private fun SingleMediaPreview(
    url: String,
    tags: List<List<String>>,
    sourceKey: MediaSourceKey,
    onMediaClick: (String) -> Unit,
    autoplay: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val isVideo = isVideoUrl(url)

    // Size to the media's natural aspect ratio — capped at 400dp landscape /
    // 600dp portrait. Matches iOS FeedMediaView (Fit, no crop).
    val painter = rememberAsyncImagePainter(
        model = ImageRequest.Builder(context)
            .data(remember(url, tags) { feedImageModel(tags, url) })
            .size(800)
            .crossfade(100)
            .build(),
    )
    val decodedRatio = (painter.state as? AsyncImagePainter.State.Success)?.let {
        val size = painter.intrinsicSize
        if (size.width > 0f && size.height > 0f) size.width / size.height else null
    }

    // What the author told us, or what an earlier decode taught us. With either,
    // the box is right before the bytes arrive and nothing below this note moves.
    val hintedRatio = remember(url, tags) { knownAspectRatio(tags, url) }

    // Remember what we decode so this URL never shifts the feed again, however
    // many times the LazyColumn recycles the row.
    LaunchedEffect(url, decodedRatio) {
        decodedRatio?.let { MediaAspectCache.put(url, it) }
    }

    // The hint wins while it exists, so the height does not change *again* when
    // the decode lands and reports a ratio a rounded `dim` disagrees with by a
    // pixel.
    val ratio = hintedRatio ?: decodedRatio

    val loaded = painter.state is AsyncImagePainter.State.Success

    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val cap = if (ratio != null && ratio < 1f) 600.dp else 400.dp
        val displayHeight = if (ratio != null) minOf(maxWidth / ratio, cap) else 200.dp
        // Square to its edges, with no rounded frame, and grey only while
        // the photo loads (iOS #286, Logen: screen room).
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .height(displayHeight)
                .mediaZoomSource(sourceKey)
                .clipToBounds()
                .then(if (loaded) Modifier else Modifier.background(TertiaryGroupedBg))
                .clickable { onMediaClick(url) },
        ) {
            BlurHashPreview(
                url = url,
                tags = tags,
                ratio = ratio,
                loaded = loaded,
            )
            Image(
                painter = painter,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
            if (isVideo && autoplay) {
                InlineFeedVideo(key = sourceKey, url = url, modifier = Modifier.matchParentSize())
            } else if (isVideo) {
                Icon(
                    imageVector = NostrVaultIcons.PlayCircle,
                    contentDescription = "Video",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(32.dp),
                )
            }
        }
    }
}

/**
 * What the feed asks Coil for to show [url]: the URL itself, except for a video
 * whose `imeta` names a poster image (`image`, or the older `thumb`), which is
 * a small JPEG instead of a frame read out of the video.
 */
internal fun feedImageModel(tags: List<List<String>>, url: String): String =
    if (isVideoUrl(url)) {
        (imetaField(tags, url, "image") ?: imetaField(tags, url, "thumb"))
            ?.takeIf { isWebUrl(it) } ?: url
    } else url

/** A poster comes from the note's author, so only a web URL is fetched, never file: or content:. */
private fun isWebUrl(s: String): Boolean =
    s.startsWith("https://", ignoreCase = true) || s.startsWith("http://", ignoreCase = true)

/**
 * What a photo shows before its pixels arrive: the NIP-92 `blurhash` preview,
 * stretched over exactly the rect the `Fit` image will occupy. Without a
 * blurhash it draws nothing and the card fill shows, as before. iOS parity:
 * `MediaLoadingPlaceholder`.
 */
@Composable
private fun BlurHashPreview(
    url: String,
    tags: List<List<String>>,
    ratio: Float?,
    loaded: Boolean,
) {
    val preview = remember(url, tags) {
        BlurHash.bitmap(imetaField(tags, url, "blurhash"))?.asImageBitmap()
    } ?: return
    // Stay under the arriving image until its 100ms crossfade has finished;
    // dropping the preview at once would flash the empty card between the two.
    var gone by remember(url) { mutableStateOf(false) }
    LaunchedEffect(loaded) {
        if (loaded) {
            delay(250)
            gone = true
        }
    }
    if (gone) return
    Image(
        bitmap = preview,
        contentDescription = null,
        contentScale = ContentScale.FillBounds,
        modifier = if (ratio != null) Modifier.aspectRatio(ratio) else Modifier.fillMaxSize(),
    )
}

@Composable
private fun MediaCarousel(
    urls: List<String>,
    tags: List<List<String>>,
    origin: Long,
    onMediaClick: (Int) -> Unit,
    autoplay: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val pagerState = rememberPagerState(pageCount = { urls.size })

    // Follow the full-screen viewer as it pages, so closing it on the third
    // photo zooms back into a carousel showing the third photo.
    val viewerPosition by FullScreenMediaRouter.position.collectAsState()
    LaunchedEffect(viewerPosition) {
        val p = viewerPosition ?: return@LaunchedEffect
        if (p.origin == origin && p.index in urls.indices && p.index != pagerState.currentPage) {
            pagerState.scrollToPage(p.index)
        }
    }

    // A pager has one height for every page, so the ratio comes from the first
    // image — the one you see before you swipe — and the first page fits it
    // exactly. Every page fills the frame edge to edge, cropping a page whose
    // shape differs, rather than sitting letterboxed in a grey box (iOS #286,
    // Logen 2026-10-05).
    //
    // This used to be a hard `aspectRatio(4f / 3f)`, which cropped even the
    // first photo: a portrait one displayed whole when posted alone lost its
    // top and bottom the moment a second image joined it.
    val firstRatio = remember(urls, tags) { knownAspectRatio(tags, urls.first()) }
    val pagerRatio = (firstRatio ?: (4f / 3f)).coerceIn(2f / 3f, 16f / 9f)

    Column(modifier = modifier) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(pagerRatio)
                .clipToBounds(),
        ) { page ->
            val url = urls[page]
            var loaded by remember(url) { mutableStateOf(false) }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .mediaZoomSource(MediaSourceKey(origin, page))
                    .then(if (loaded) Modifier else Modifier.background(TertiaryGroupedBg))
                    .clickable { onMediaClick(page) },
            ) {
                BlurHashPreview(
                    url = url,
                    tags = tags,
                    ratio = remember(url, tags) { knownAspectRatio(tags, url) },
                    loaded = loaded,
                )
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(remember(url, tags) { feedImageModel(tags, url) })
                        .size(800)
                        .crossfade(100)
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    onSuccess = { result ->
                        loaded = true
                        val d = result.result.drawable
                        if (d.intrinsicWidth > 0 && d.intrinsicHeight > 0) {
                            MediaAspectCache.put(
                                url,
                                d.intrinsicWidth.toFloat() / d.intrinsicHeight.toFloat(),
                            )
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
                if (isVideoUrl(url) && autoplay && page == pagerState.currentPage) {
                    // Only the page in view is a candidate; the others keep a poster.
                    InlineFeedVideo(
                        key = MediaSourceKey(origin, page),
                        url = url,
                        modifier = Modifier.matchParentSize(),
                    )
                } else if (isVideoUrl(url)) {
                    Icon(
                        imageVector = NostrVaultIcons.PlayCircle,
                        contentDescription = "Video",
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
        }

        // Page-position bar
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
        ) {
            PagePositionBar(
                count = urls.size,
                index = pagerState.currentPage,
                track = SecondaryText.copy(alpha = 0.25f),
                lit = LocalNostrVaultColors.current.primary,
            )
        }
    }
}

/**
 * Thin position bar for a multi-image note: a hairline track with one slot per item and
 * the current slot lit, sliding as the pager settles. Mirrors iOS PagePositionBar.
 */
@Composable
internal fun PagePositionBar(
    count: Int,
    index: Int,
    track: Color,
    lit: Color,
    modifier: Modifier = Modifier,
) {
    if (count < 2) return
    // Slots shrink as the count grows so a long post still fits under a narrow card.
    val slot = (140f / count).coerceIn(8f, 18f).dp
    val clamped = index.coerceIn(0, count - 1)
    val offset by androidx.compose.animation.core.animateDpAsState(
        targetValue = slot * clamped,
        label = "pagePositionBar",
    )
    Box(
        modifier = modifier
            .size(width = slot * count, height = 2.5.dp)
            .clip(RoundedCornerShape(50))
            .background(track),
    ) {
        Box(
            modifier = Modifier
                .offset(x = offset)
                .size(width = slot, height = 2.5.dp)
                .clip(RoundedCornerShape(50))
                .background(lit),
        )
    }
}

// ── Parent note preview ──────────────────────────────────────────

/**
 * Parent note preview shown inside a reply card when the parent
 * is not the immediately preceding card in the feed.
 * Matches the iOS layout: 40dp avatar + connector line on the left,
 * name/timestamp + content + media on the right.
 */
@Composable
private fun ParentNotePreview(
    parentNote: FeedNote,
    parentProfile: FeedProfile?,
    connectorColor: Color,
    onClick: () -> Unit,
    profiles: Map<String, FeedProfile> = emptyMap(),
    avatarMenu: AvatarMenuActions? = null,
    onProfileClick: (String) -> Unit = {},
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
                    displayName = parentProfile?.bestName ?: parentNote.pubkey.take(8) + "...",
                    menu = avatarMenu,
                    onProfileClick = onProfileClick,
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
            // Header: name + NIP-05 badge, timestamp on line below
            Column(modifier = Modifier.padding(top = 4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = parentProfile?.bestName ?: parentNote.pubkey.take(8) + "...",
                        color = Color(0xFFD9D9D9), // iOS: rgb(0.85, 0.85, 0.85)
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )

                    if (!parentProfile?.nip05.isNullOrBlank()) {
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            imageVector = NostrVaultIcons.Verified,
                            contentDescription = "Verified",
                            tint = Color(0xFF33CC99),
                            modifier = Modifier.size(12.dp),
                        )
                    }
                    if (parentNote.isFromNostrVault) {
                        Spacer(Modifier.width(4.dp))
                        NostrVaultBadge(size = 10.dp)
                    }
                }

                Text(
                    text = formatTimestamp(parentNote.createdAt.time / 1000),
                    color = SecondaryText,
                    fontSize = 11.sp,
                )
            }

            // Content text (2 lines max, matching iOS)
            if (parentNote.content.isNotBlank()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = remember(parentNote.content, profiles) {
                        NostrMentions.toPlainText(parentNote.content, profiles, parentNote.mediaURLs.toSet()).replace("\n", " ")
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
private fun ParentNoteFailed(onRetry: (() -> Unit)?) {
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
private fun ParentNoteSkeleton(
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

// ── Formatting helpers ────────────────────────────────────────────

internal fun formatTimestamp(epochSecs: Long): String =
    formatTimestamp(epochSecs, System.currentTimeMillis() / 1000)

/**
 * Relative time for a week, then a date: "Sep 24" for this year,
 * "Sep 24, 2025" for any other year (iOS `relativeTime`, PR #69).
 */
internal fun formatTimestamp(
    epochSecs: Long,
    nowSecs: Long,
    zone: java.time.ZoneId = java.time.ZoneId.systemDefault(),
    locale: java.util.Locale = java.util.Locale.getDefault(),
): String {
    val diff = nowSecs - epochSecs
    return when {
        diff < 60 -> "now"
        diff < 3600 -> "${diff / 60}m"
        diff < 86400 -> "${diff / 3600}h"
        diff < 604800 -> "${diff / 86400}d"
        else -> {
            val date = java.time.Instant.ofEpochSecond(epochSecs).atZone(zone)
            val sameYear = date.year == java.time.Instant.ofEpochSecond(nowSecs).atZone(zone).year
            val pattern = if (sameYear) "MMM d" else "MMM d, yyyy"
            java.time.format.DateTimeFormatter.ofPattern(pattern, locale).format(date)
        }
    }
}

