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
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.graphics.Color
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
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NoteStats
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaCacheService
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
 * Reusable note card used across Feed, Profile, Search, and NoteDetail screens.
 * Renders author header, content, media thumbnails, and engagement actions.
 */
@Composable
fun NoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    stats: NoteStats?,
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
                        note.pubkey,
                        note.kind,
                    ) ?: HavenBridge.hexToNote1(note.effectiveEventId)
                        ?: note.effectiveEventId
                    menuClipboard.setText(AnnotatedString(threadLink(nevent)))
                    Toast.makeText(menuContext, "Link copied", Toast.LENGTH_SHORT).show()
                },
            ),
        )
        onBroadcast?.let { broadcast ->
            add(NoteAction(NostrVaultIcons.Relay, "Broadcast", onClick = { broadcast(note.effectiveEventId) }))
        }
        if (isOwnNote) {
            onDelete?.let {
                add(NoteAction(NostrVaultIcons.Delete, "Delete Post", destructive = true, onClick = it))
            }
        } else {
            onReport?.let {
                add(NoteAction(NostrVaultIcons.Alert, "Report", destructive = true, onClick = it))
            }
            onBlock?.let {
                add(NoteAction(NostrVaultIcons.Blocked, "Block", destructive = true, onClick = it))
            }
        }
    }
    val connectorColor = colors.primary.copy(alpha = 0.3f)

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
        // Unfocused cards get a neutral hairline, not accent-at-18%. Every card in
        // the feed carrying an orange outline spends the accent on structure,
        // which is what the accent is for drawing the eye *away* from. Focus
        // still gets the accent, at full strength, where it means something.
        border = BorderStroke(
            if (isFocused) 2.dp else if (isOled) 1.dp else 0.8.dp,
            if (isFocused) colors.primary else SeparatorColor.copy(alpha = if (isOled) 0.9f else 0.6f),
        ),
        // No shadow: 8dp of it is not legible on a near-black surface. The 2dp
        // accent border above is what says "focused".
        shadowElevation = 0.dp,
        modifier = modifier
            .fillMaxWidth()
            .then(connectorModifier)
            .clickable { onNoteClick(note.id) },
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
                    )
                } else {
                    ParentNoteSkeleton(connectorColor = connectorColor)
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
                // Avatar
                AvatarImage(
                    url = profile?.pictureURL,
                    pubkey = note.pubkey,
                    size = 40.dp,
                    displayName = profile?.bestName,
                    modifier = Modifier.clickable { onProfileClick(note.pubkey) },
                )

                Spacer(Modifier.width(10.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = profile?.bestName ?: note.pubkey.take(8) + "...",
                            color = PrimaryText,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
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

                        Spacer(Modifier.weight(1f))

                        Text(
                            text = formatTimestamp(note.createdAt.time / 1000),
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

            // Content text (rich: clickable mentions, links, hashtags)
            if (note.content.isNotBlank()) {
                NostrContentText(
                    content = note.content,
                    profiles = profiles,
                    mediaURLs = note.mediaURLs.toSet(),
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                    onProfileClick = onProfileClick,
                    onPlainTextClick = { onNoteClick(note.id) },
                    modifier = Modifier.padding(start = 50.dp),
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
                            modifier = Modifier.padding(start = 50.dp),
                        )
                    } else {
                        QuotedNotePlaceholder(
                            identifier = qid,
                            onClick = onNoteClick,
                            modifier = Modifier.padding(start = 50.dp),
                        )
                    }
                    Spacer(Modifier.height(4.dp))
                }
            }

            // Link preview (first non-media URL, only if no quoted notes)
            if (note.quotedEventIds.isEmpty() && note.linkURLs.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                LinkPreviewCard(
                    url = note.linkURLs.first(),
                    modifier = Modifier.padding(start = 50.dp),
                )
            }

            // Media thumbnails
            if (note.mediaURLs.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                MediaPreviewRow(
                    urls = note.mediaURLs,
                    tags = note.tags,
                    modifier = Modifier.padding(start = 50.dp),
                )
            }

            Spacer(Modifier.height(8.dp))

            // Engagement bar — use effectiveEventId so that interactions
            // (reply, like, repost, zap) target the original note for kind-6
            // reposts, not the repost wrapper event.
            EngagementBar(
                noteId = note.effectiveEventId,
                stats = stats,
                isLiked = isLiked,
                isZapped = isZapped,
                isReposted = isReposted,
                onReply = onReply,
                onRepost = onRepost,
                onQuote = onQuote,
                onLike = onLike,
                onZap = onZap,
                onLongPressLike = onLongPressLike,
            )
        }
        } // Box (focused tint overlay)
    }
}

/**
 * Action button row. Mirrors the iOS feed note layout: capsule-background
 * icon buttons, left-aligned with fixed spacing, with a spring scale-up on
 * active states.
 * Order: Reply → Repost → Quote → Like → Zap.
 *
 * Repost, Like and Zap carry their count when there is one. Reply does not:
 * [NoteStats] has no reply count, and inventing one from the loaded thread would
 * be wrong for any note whose replies are not in the cache.
 *
 * **Five buttons, because seven plus three counts does not fit a phone.** A
 * 360dp device leaves this row 312dp once the card's 10dp a side and the
 * column's 14dp a side are paid for. Seven 32dp buttons at 12dp spacing are
 * 296dp *icon-only* — already over once the old 50dp text indent was on it —
 * and a count adds its glyphs plus a 3dp gap to three of them: 3×58 + 4×32 +
 * 6×8 = 350dp. No arrangement fixes that; membership does. Share and Broadcast
 * moved to the overflow menu (neither carries a count, both are secondary to
 * Reply/Repost/Like/Zap, and Share sits next to Copy link where it belongs),
 * leaving 3×58 + 2×32 = 238dp.
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
    stats: NoteStats?,
    isLiked: Boolean,
    isZapped: Boolean,
    isReposted: Boolean = false,
    onReply: ((String) -> Unit)?,
    onRepost: ((String) -> Unit)?,
    onQuote: ((String) -> Unit)?,
    onLike: ((String) -> Unit)?,
    onZap: ((String) -> Unit)?,
    onLongPressLike: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth(),
    ) {
        // Reply
        if (onReply != null) {
            EngagementButton(
                icon = NostrVaultIcons.Reply,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Reply",
                onClick = { onReply.invoke(noteId) },
            )
        }

        // Repost
        if (onRepost != null) {
            EngagementButton(
                icon = NostrVaultIcons.Repost,
                isActive = isReposted,
                activeColor = RepostGreen,
                contentDescription = if (isReposted) "Reposted" else "Repost",
                count = engagementCountLabel(stats?.repostCount ?: 0),
                onClick = { onRepost.invoke(noteId) },
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
            )
        }

        // Like (with long-press for emoji picker) — hidden entirely in Zaps Only mode
        if (onLike != null && !LocalZapsOnlyMode.current) {
            EngagementButton(
                icon = if (isLiked) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
                isActive = isLiked,
                activeColor = LikeRed,
                contentDescription = if (isLiked) "Unlike" else "Like",
                count = engagementCountLabel(stats?.reactionCount ?: 0),
                onClick = { onLike.invoke(noteId) },
                onLongClick = if (onLongPressLike != null) {
                    { onLongPressLike.invoke(noteId) }
                } else null,
            )
        }

        // Zap
        if (onZap != null) {
            EngagementButton(
                icon = NostrVaultIcons.Zap,
                isActive = isZapped,
                activeColor = ZapOrange,
                contentDescription = if (isZapped) "Zapped" else "Zap",
                count = zapCountLabel(stats?.zapCount ?: 0, stats?.zapAmountSats ?: 0L),
                onClick = { onZap.invoke(noteId) },
            )
        }

        // Slack stays here, at the end, rather than being spread between the
        // buttons — see the arrangement note above.
        Spacer(Modifier.weight(1f))
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
) {
    val tint = if (isActive) activeColor else SecondaryText
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
        if (!Motion.isReduced) pulsing = true
        onClick()
    }

    val clickModifier = if (onLongClick != null) {
        Modifier.combinedClickable(onClick = tapAndPulse, onLongClick = onLongClick)
    } else {
        Modifier.clickable(onClick = tapAndPulse)
    }

    // With a count the button becomes a capsule wide enough for the number; with
    // none it stays the 32dp circle it has always been. Height is fixed at 32dp
    // either way so a row of mixed buttons does not step up and down as counts
    // arrive from backfill.
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .scale(scale)
            .height(32.dp)
            .then(if (count == null) Modifier.width(32.dp) else Modifier.widthIn(min = 32.dp))
            .clip(CircleShape)
            .background(background)
            .then(clickModifier)
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
            )
        }
    }
}

private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "webm", "avi", "mkv", "m4v")

internal fun isVideoUrl(url: String): Boolean {
    val ext = url.substringAfterLast('.').substringBefore('?').lowercase()
    return ext in VIDEO_EXTENSIONS
}

@Composable
fun MediaPreviewRow(
    urls: List<String>,
    /** The note's tags, read for NIP-92 `imeta dim` so the box is right first time. */
    tags: List<List<String>> = emptyList(),
    modifier: Modifier = Modifier,
) {
    if (urls.size == 1) {
        SingleMediaPreview(
            url = urls.first(),
            tags = tags,
            onMediaClick = { FullScreenMediaRouter.open(urls, 0) },
            modifier = modifier,
        )
    } else {
        MediaCarousel(
            urls = urls,
            tags = tags,
            onMediaClick = { index -> FullScreenMediaRouter.open(urls, index) },
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
 */
@Composable
internal fun FullScreenMediaPager(
    urls: List<String>,
    initialIndex: Int,
    onDismiss: () -> Unit,
    viewModel: FeedMediaMirrorViewModel = hiltViewModel(),
) {
    val mirrorState by viewModel.state.collectAsState()
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

    BackHandler(onBack = onDismiss)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = backgroundAlpha))
            // Swallow taps that no child consumed so they can't reach the UI beneath
            .pointerInput(Unit) { detectTapGestures { } },
    ) {
            HorizontalPager(
                state = pagerState,
                // Lock paging while a page is zoomed so pan doesn't flip pages.
                userScrollEnabled = currentScale <= 1.05f,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        translationY = dragOffsetY.value
                        scaleX = contentScale
                        scaleY = contentScale
                    },
            ) { page ->
                val url = urls[page]
                if (isVideoUrl(url)) {
                    // Only the visible page gets a player, to keep memory at one instance.
                    if (page == pagerState.currentPage) {
                        VideoPlayer(uri = url, modifier = Modifier.fillMaxSize())
                    } else {
                        Box(Modifier.fillMaxSize().background(Color.Black))
                    }
                } else {
                    ZoomableImage(
                        model = url,
                        contentDescription = null,
                        onScaleChanged = { currentScale = it },
                        onVerticalDrag = { deltaY ->
                            if (currentScale <= 1.05f) {
                                accumulatedDragY += deltaY
                                scope.launch { dragOffsetY.snapTo(accumulatedDragY) }
                            }
                        },
                        onVerticalDragEnd = {
                            if (abs(accumulatedDragY) > dismissThresholdPx) {
                                onDismiss()
                            } else {
                                scope.launch {
                                    dragOffsetY.animateTo(0f, Motion.snapBack())
                                }
                            }
                            accumulatedDragY = 0f
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            if (!isInPiP) {
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .statusBarsPadding()
                        .padding(8.dp)
                        .size(40.dp)
                        .graphicsLayer { alpha = overlayAlpha }
                        .background(Color.Black.copy(alpha = 0.4f), CircleShape),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Dismiss,
                        contentDescription = "Close",
                        tint = Color.White,
                    )
                }
            }

            if (!isInPiP && viewModel.canMirror) {
                MirrorToBlossomPill(
                    state = mirrorState,
                    onMirror = { viewModel.mirror(currentUrl) },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(8.dp)
                        .graphicsLayer { alpha = overlayAlpha },
                )
            }

            // Page-position dots, only when the note carries more than one item.
            if (urls.size > 1 && !isInPiP) {
                Row(
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 24.dp)
                        .graphicsLayer { alpha = overlayAlpha },
                ) {
                    repeat(urls.size) { i ->
                        val selected = i == pagerState.currentPage
                        Box(
                            modifier = Modifier
                                .padding(horizontal = 3.dp)
                                .size(if (selected) 8.dp else 6.dp)
                                .clip(CircleShape)
                                .background(
                                    if (selected) Color.White
                                    else Color.White.copy(alpha = 0.4f),
                                ),
                        )
                    }
                }
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

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .then(if (clickable) Modifier.clickable(onClick = onMirror) else Modifier)
            .padding(horizontal = 14.dp, vertical = 8.dp),
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
                Text("Mirrored to Blossom", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            is FeedMediaMirrorViewModel.MirrorState.Failed -> {
                Icon(NostrVaultIcons.Dismiss, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Mirror failed — retry", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            FeedMediaMirrorViewModel.MirrorState.Idle -> {
                Icon(NostrVaultIcons.Backup, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Mirror to Blossom", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@HiltViewModel
class FeedMediaMirrorViewModel @Inject constructor(
    private val blossomService: BlossomService,
    private val mediaCacheService: MediaCacheService,
) : ViewModel() {

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
    onMediaClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val isVideo = isVideoUrl(url)

    // Size to the media's natural aspect ratio — capped at 400dp landscape /
    // 600dp portrait. Matches iOS FeedMediaView (Fit, no crop).
    val painter = rememberAsyncImagePainter(
        model = ImageRequest.Builder(context)
            .data(url)
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

    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val cap = if (ratio != null && ratio < 1f) 600.dp else 400.dp
        val displayHeight = if (ratio != null) minOf(maxWidth / ratio, cap) else 200.dp
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .height(displayHeight)
                .clip(RoundedCornerShape(8.dp))
                .background(TertiaryGroupedBg)
                .clickable { onMediaClick(url) },
        ) {
            Image(
                painter = painter,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
            if (isVideo) {
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

@Composable
private fun MediaCarousel(
    urls: List<String>,
    tags: List<List<String>>,
    onMediaClick: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val pagerState = rememberPagerState(pageCount = { urls.size })

    // A pager has one height for every page, so the ratio comes from the first
    // image — the one you see before you swipe. Pages are drawn Fit inside it,
    // which letterboxes the others rather than cropping them.
    //
    // This used to be a hard `aspectRatio(4f / 3f)` with `ContentScale.Crop`, so
    // a portrait photo displayed whole when posted alone and was centre-cropped
    // into a landscape box the moment a second image joined it. Faces and text
    // went off the edges of the same file that rendered fine on its own.
    val firstRatio = remember(urls, tags) { knownAspectRatio(tags, urls.first()) }
    val pagerRatio = (firstRatio ?: (4f / 3f)).coerceIn(2f / 3f, 16f / 9f)

    Column(modifier = modifier) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(pagerRatio)
                .clip(RoundedCornerShape(8.dp)),
        ) { page ->
            val url = urls[page]
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .background(TertiaryGroupedBg)
                    .clickable { onMediaClick(page) },
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(url)
                        .size(800)
                        .crossfade(100)
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    onSuccess = { result ->
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
                if (isVideoUrl(url)) {
                    Icon(
                        imageVector = NostrVaultIcons.PlayCircle,
                        contentDescription = "Video",
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
        }

        // Page indicator dots
        Row(
            horizontalArrangement = Arrangement.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 6.dp),
        ) {
            repeat(urls.size) { i ->
                Box(
                    modifier = Modifier
                        .padding(horizontal = 2.dp)
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(
                            if (i == pagerState.currentPage)
                                LocalNostrVaultColors.current.primary
                            else
                                SecondaryText.copy(alpha = 0.3f)
                        ),
                )
            }
        }
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
            AvatarImage(
                url = parentProfile?.pictureURL,
                pubkey = parentNote.pubkey,
                size = 40.dp,
                displayName = parentProfile?.bestName,
            )
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

        // Right column: skeleton bars
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(top = 4.dp),
        ) {
            Row {
                Box(
                    modifier = Modifier
                        .width(80.dp)
                        .height(12.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(TertiaryGroupedBg),
                )
                Spacer(Modifier.weight(1f))
                Box(
                    modifier = Modifier
                        .width(40.dp)
                        .height(10.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(TertiaryGroupedBg),
                )
            }
            Spacer(Modifier.height(5.dp))
            Box(
                modifier = Modifier
                    .width(180.dp)
                    .height(12.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(TertiaryGroupedBg),
            )
        }
    }
}

// ── Formatting helpers ────────────────────────────────────────────

internal fun formatTimestamp(epochSecs: Long): String {
    val now = System.currentTimeMillis() / 1000
    val diff = now - epochSecs
    return when {
        diff < 60 -> "now"
        diff < 3600 -> "${diff / 60}m"
        diff < 86400 -> "${diff / 3600}h"
        diff < 604800 -> "${diff / 86400}d"
        else -> "${diff / 604800}w"
    }
}

