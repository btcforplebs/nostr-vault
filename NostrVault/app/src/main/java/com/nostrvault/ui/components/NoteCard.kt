package com.nostrvault.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NoteStats
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

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
    isFocused: Boolean = false,
    showReplyContext: Boolean = false,
    parentIsNext: Boolean = false,
    hasReplyBelow: Boolean = false,
    parentNote: FeedNote? = null,
    repostedByProfile: FeedProfile? = null,
    replyToProfile: FeedProfile? = null,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onLike: ((String) -> Unit)? = null,
    onRepost: ((String) -> Unit)? = null,
    onZap: ((String) -> Unit)? = null,
    onReply: ((String) -> Unit)? = null,
    onQuote: ((String) -> Unit)? = null,
    onShare: ((String) -> Unit)? = null,
    onBroadcast: ((String) -> Unit)? = null,
    onMore: ((String) -> Unit)? = null,
    onLongPressLike: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val isOled = LocalOledMode.current
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
        border = BorderStroke(
            if (isFocused) 2.dp else if (isOled) 1.dp else 0.8.dp,
            if (isFocused) colors.primary else colors.primary.copy(alpha = if (isOled) 0.18f else 0.12f),
        ),
        shadowElevation = if (isFocused) 8.dp else 0.dp,
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
                            fontSize = 15.sp,
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
                    }
                    Text(
                        text = formatTimestamp(note.createdAt.time / 1000),
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }

                // More menu
                onMore?.let { handler ->
                    IconButton(onClick = { handler(note.id) }) {
                        Icon(
                            imageVector = NostrVaultIcons.More,
                            contentDescription = "More",
                            tint = SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
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
                    onProfileClick = onProfileClick,
                    onNoteClick = onNoteClick,
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
                            onClick = onNoteClick,
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
                    modifier = Modifier.padding(start = 50.dp),
                )
            }

            Spacer(Modifier.height(8.dp))

            // Engagement bar
            EngagementBar(
                noteId = note.id,
                isLiked = isLiked,
                isZapped = isZapped,
                onReply = onReply,
                onRepost = onRepost,
                onQuote = onQuote,
                onLike = onLike,
                onZap = onZap,
                onShare = onShare,
                onBroadcast = onBroadcast,
                onLongPressLike = onLongPressLike,
                modifier = Modifier.padding(start = 50.dp),
            )
        }
        } // Box (focused tint overlay)
    }
}

/**
 * Action button row. Mirrors the iOS feed note layout: capsule-background
 * icon buttons, left-aligned with fixed spacing, icon-only (no counts), with a
 * spring scale-up on active states.
 * Order: Reply → Repost → Quote → Like → Zap → Share → Broadcast.
 */
@Composable
private fun EngagementBar(
    noteId: String,
    isLiked: Boolean,
    isZapped: Boolean,
    onReply: ((String) -> Unit)?,
    onRepost: ((String) -> Unit)?,
    onQuote: ((String) -> Unit)?,
    onLike: ((String) -> Unit)?,
    onZap: ((String) -> Unit)?,
    onShare: ((String) -> Unit)?,
    onBroadcast: ((String) -> Unit)?,
    onLongPressLike: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth(),
    ) {
        // Reply
        EngagementButton(
            icon = NostrVaultIcons.Reply,
            isActive = false,
            activeColor = SecondaryText,
            contentDescription = "Reply",
            onClick = { onReply?.invoke(noteId) },
        )

        // Repost
        EngagementButton(
            icon = NostrVaultIcons.Repost,
            isActive = false,
            activeColor = RepostGreen,
            contentDescription = "Repost",
            onClick = { onRepost?.invoke(noteId) },
        )

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

        // Like (with long-press for emoji picker)
        EngagementButton(
            icon = if (isLiked) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
            isActive = isLiked,
            activeColor = LikeRed,
            contentDescription = if (isLiked) "Unlike" else "Like",
            onClick = { onLike?.invoke(noteId) },
            onLongClick = if (onLongPressLike != null) {
                { onLongPressLike.invoke(noteId) }
            } else null,
        )

        // Zap
        EngagementButton(
            icon = NostrVaultIcons.Zap,
            isActive = isZapped,
            activeColor = ZapOrange,
            contentDescription = if (isZapped) "Zapped" else "Zap",
            onClick = { onZap?.invoke(noteId) },
        )

        // Share
        EngagementButton(
            icon = NostrVaultIcons.Share,
            isActive = false,
            activeColor = SecondaryText,
            contentDescription = "Share",
            onClick = { onShare?.invoke(noteId) },
        )

        // Broadcast
        if (onBroadcast != null) {
            EngagementButton(
                icon = NostrVaultIcons.Relay,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Broadcast",
                onClick = { onBroadcast.invoke(noteId) },
            )
        }

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
) {
    val tint = if (isActive) activeColor else SecondaryText
    val background = if (isActive) {
        activeColor.copy(alpha = 0.18f)
    } else {
        SecondaryText.copy(alpha = 0.10f)
    }
    // Spring scale-up on active, mirroring the iOS .spring(response: 0.3, dampingFraction: 0.45)
    val scale by animateFloatAsState(
        targetValue = if (isActive) 1.2f else 1.0f,
        animationSpec = spring(dampingRatio = 0.45f, stiffness = Spring.StiffnessMediumLow),
        label = "engagementScale",
    )

    val clickModifier = if (onLongClick != null) {
        Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick)
    } else {
        Modifier.clickable(onClick = onClick)
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .scale(scale)
            .size(32.dp)
            .clip(CircleShape)
            .background(background)
            .then(clickModifier),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = tint,
            modifier = Modifier.size(16.dp),
        )
    }
}

private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "webm", "avi", "mkv", "m4v")

private fun isVideoUrl(url: String): Boolean {
    val ext = url.substringAfterLast('.').substringBefore('?').lowercase()
    return ext in VIDEO_EXTENSIONS
}

@Composable
fun MediaPreviewRow(
    urls: List<String>,
    modifier: Modifier = Modifier,
) {
    var viewingUrl by remember { mutableStateOf<String?>(null) }

    if (urls.size == 1) {
        SingleMediaPreview(
            url = urls.first(),
            onMediaClick = { viewingUrl = it },
            modifier = modifier,
        )
    } else {
        MediaCarousel(
            urls = urls,
            onMediaClick = { viewingUrl = it },
            modifier = modifier,
        )
    }

    viewingUrl?.let { url ->
        FullScreenMediaDialog(
            url = url,
            onDismiss = { viewingUrl = null },
        )
    }
}

@Composable
private fun FullScreenMediaDialog(
    url: String,
    onDismiss: () -> Unit,
    viewModel: FeedMediaMirrorViewModel = hiltViewModel(),
) {
    val mirrorState by viewModel.state.collectAsState()

    // Re-evaluate the starting state each time a new URL is opened in the viewer
    // (the ViewModel is shared across the feed, so only one viewer is ever active).
    LaunchedEffect(url) { viewModel.onOpen(url) }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            if (isVideoUrl(url)) {
                VideoPlayer(uri = url)
            } else {
                ZoomableImage(
                    model = url,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                )
            }

            IconButton(
                onClick = onDismiss,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(8.dp)
                    .size(40.dp)
                    .background(Color.Black.copy(alpha = 0.4f), CircleShape),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Dismiss,
                    contentDescription = "Close",
                    tint = Color.White,
                )
            }

            if (viewModel.canMirror) {
                MirrorToBlossomPill(
                    state = mirrorState,
                    onMirror = { viewModel.mirror(url) },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(8.dp),
                )
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
    onMediaClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(8.dp))
            .background(TertiaryGroupedBg)
            .clickable { onMediaClick(url) },
    ) {
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data(url)
                .size(800)
                .crossfade(100)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
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

@Composable
private fun MediaCarousel(
    urls: List<String>,
    onMediaClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val pagerState = rememberPagerState(pageCount = { urls.size })

    Column(modifier = modifier) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(4f / 3f)
                .clip(RoundedCornerShape(8.dp)),
        ) { page ->
            val url = urls[page]
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .background(TertiaryGroupedBg)
                    .clickable { onMediaClick(url) },
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(url)
                        .size(800)
                        .crossfade(100)
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
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
                    text = parentNote.content.replace("\n", " "),
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

internal fun formatCount(count: Int): String {
    return when {
        count < 1000 -> count.toString()
        count < 10_000 -> "%.1fk".format(count / 1000.0)
        count < 1_000_000 -> "${count / 1000}k"
        else -> "%.1fM".format(count / 1_000_000.0)
    }
}
