package com.nostrvault.ui.screens.feed

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.Reel
import com.nostrvault.data.model.ReelCursors
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.ThinSeekBar
import com.nostrvault.ui.components.VideoSurface
import com.nostrvault.ui.components.buildLoopingExoPlayer
import com.nostrvault.ui.components.formatTimestamp
import com.nostrvault.ui.components.shareNote
import com.nostrvault.ui.navigation.FloatingNavBarInset
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlin.math.abs

/**
 * Reels: full-screen videos, one per page, swiped vertically. Port of iOS
 * `ReelsFeedView`.
 *
 * Only the page on screen plays. Its neighbours build their players ahead of
 * time so a swipe lands on a video that is already buffering; anything further
 * away has no player at all, so at most three exist.
 *
 * Players are built and torn down synchronously in effects, and whether one
 * plays is re-applied from the page's current state every time that state
 * changes — there is no async setup that could finish after the page has
 * scrolled away and start a video off screen.
 */
@Composable
internal fun ReelsFeed(
    viewModel: FeedViewModel,
    profiles: Map<String, FeedProfile>,
    /** Height of the toolbar laid over the top of the page. */
    topInset: Dp,
    /**
     * A sheet or dialog is over the feed. The reel under it must go quiet:
     * being covered does not take the page out of composition.
     */
    isCovered: Boolean,
    onProfile: (String) -> Unit,
    onReply: (FeedNote) -> Unit,
    onOpenNote: (FeedNote) -> Unit,
    onShowGlobal: () -> Unit,
) {
    val reels by viewModel.reels.collectAsState()
    val isLoading by viewModel.reelsLoading.collectAsState()
    val isLoadingMore by viewModel.reelsLoadingMore.collectAsState()
    val loadFailed by viewModel.reelsLoadFailed.collectAsState()
    val followSetIsEmpty by viewModel.reelsFollowSetIsEmpty.collectAsState()
    val scope by viewModel.reelsScope.collectAsState()
    val isMuted by viewModel.reelsMuted.collectAsState()
    val isLoadingContacts by viewModel.isLoadingContacts.collectAsState()
    val followedPubkeys by viewModel.followedPubkeys.collectAsState()
    val likedIds by viewModel.likedEventIds.collectAsState()

    // Backgrounded, or another screen pushed over this one: the lifecycle of
    // the nav entry drops below RESUMED either way.
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val isForeground = lifecycleState.isAtLeast(Lifecycle.State.RESUMED)

    // The page draws edge to edge; its chrome clears the floating nav bar, or
    // the system navigation bar when there is no floating one.
    val navBarHeight by FloatingNavBarInset.height
    val systemBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val bottomInset = maxOf(navBarHeight, systemBottom)

    LaunchedEffect(Unit) {
        viewModel.loadReelsIfNeeded()
        // A profile opened from a reel can block its author; drop their reels
        // on the way back.
        viewModel.pruneBlockedReels()
    }

    // At launch the follow set can land after this asked for it; "you aren't
    // following anyone" must not outlive the contact load.
    val followsEmpty = followedPubkeys.isEmpty()
    LaunchedEffect(followsEmpty) {
        if (!followsEmpty && followSetIsEmpty && scope == ReelsScope.FOLLOWING) viewModel.refreshReels()
    }

    LaunchedEffect(reels) {
        if (reels.isNotEmpty()) viewModel.fetchMissingProfiles(reels.take(60).map { it.note.pubkey }.distinct())
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        if (reels.isEmpty()) {
            if (isLoading || isLoadingMore || (followSetIsEmpty && isLoadingContacts)) {
                CircularProgressIndicator(color = Color.White)
            } else {
                ReelsEmptyState(
                    followSetIsEmpty = followSetIsEmpty,
                    loadFailed = loadFailed,
                    scope = scope,
                    onShowGlobal = onShowGlobal,
                    onRetry = viewModel::refreshReels,
                )
            }
        } else {
            val context = LocalContext.current
            val pagerState = rememberPagerState(pageCount = { reels.size })
            val settledPage = pagerState.settledPage
            val shownId = reels.getOrNull(settledPage)?.id

            LaunchedEffect(shownId) {
                val id = shownId ?: return@LaunchedEffect
                viewModel.didShowReel(id)
                if (settledPage >= reels.size - ReelCursors.NEAR_END) viewModel.loadMoreReels()
            }

            // A load-more that no relay answered leaves the service idle, and
            // nothing else asks again while the viewer stays put near the end.
            // Retry on a slow timer until a page lands or history runs out
            // (the service ignores the call once it has).
            LaunchedEffect(shownId, isLoadingMore, reels.size) {
                if (isLoadingMore || shownId == null) return@LaunchedEffect
                if (settledPage < reels.size - ReelCursors.NEAR_END) return@LaunchedEffect
                delay(5_000)
                viewModel.loadMoreReels()
            }

            VerticalPager(
                state = pagerState,
                beyondViewportPageCount = 1,
                key = { index -> reels.getOrNull(index)?.id ?: index },
                modifier = Modifier.fillMaxSize(),
            ) { page ->
                val reel = reels[page]
                ReelPage(
                    reel = reel,
                    profile = profiles[reel.note.pubkey],
                    profiles = profiles,
                    isCurrent = page == pagerState.settledPage,
                    canPlay = isForeground && !isCovered,
                    shouldPrepare = abs(page - pagerState.currentPage) <= 1,
                    isLiked = reel.id in likedIds,
                    isMuted = isMuted,
                    bottomInset = bottomInset,
                    onToggleMute = { viewModel.setReelsMuted(!isMuted) },
                    onProfile = { onProfile(reel.note.pubkey) },
                    onReply = { onReply(reel.note) },
                    onOpenNote = { onOpenNote(reel.note) },
                    onLike = { viewModel.likeNote(reel.id) },
                    onShare = { shareNote(context, reel.note) },
                )
            }

            if (isLoadingMore && settledPage >= reels.size - 1) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = topInset + 8.dp)
                        .size(20.dp),
                )
            }
        }
    }
}

// ── One page ─────────────────────────────────────────────────────

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun ReelPage(
    reel: Reel,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile>,
    /** This is the page on screen. */
    isCurrent: Boolean,
    /** Nothing is covering the feed and the app is in front. */
    canPlay: Boolean,
    /** Within one page of the one on screen: build the player ahead of time. */
    shouldPrepare: Boolean,
    isLiked: Boolean,
    isMuted: Boolean,
    bottomInset: Dp,
    onToggleMute: () -> Unit,
    onProfile: () -> Unit,
    onReply: () -> Unit,
    onOpenNote: () -> Unit,
    onLike: () -> Unit,
    onShare: () -> Unit,
) {
    val context = LocalContext.current
    var player by remember { mutableStateOf<ExoPlayer?>(null) }
    var hasFrame by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var learnedAspect by remember { mutableStateOf<Float?>(null) }
    /** Paused by a tap, as opposed to paused because it is off screen. */
    var userPaused by remember { mutableStateOf(false) }
    var captionExpanded by remember { mutableStateOf(false) }
    var heartBursts by remember { mutableIntStateOf(0) }
    var showHeart by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }
    var isSeeking by remember { mutableStateOf(false) }

    // The player exists only inside the warm window. Leaving it — or leaving
    // composition, when the pager drops the page or the feed leaves Reels —
    // releases it, so nothing off screen can hold a decoder or make a sound.
    DisposableEffect(shouldPrepare, reel.videoUrl) {
        if (!shouldPrepare) return@DisposableEffect onDispose {}
        // Built paused and silent; the effect below decides otherwise.
        val built = buildLoopingExoPlayer(context, reel.videoUrl, playWhenReady = false, mimeType = reel.mimeType)
        built.volume = 0f
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                hasFrame = true
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    learnedAspect = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                failed = true
            }
        }
        built.addListener(listener)
        player = built
        onDispose {
            built.removeListener(listener)
            built.release()
            if (player === built) player = null
            hasFrame = false
        }
    }

    // Coming back to a reel starts it over, the way a swipe feed reads — and a
    // tap-pause does not follow it off screen.
    LaunchedEffect(isCurrent) {
        if (!isCurrent) userPaused = false
    }

    // Re-applied on every change, from the values as they are now. Only the
    // current, uncovered, foreground page plays, and only it has sound.
    val shouldPlay = isCurrent && canPlay && !userPaused
    LaunchedEffect(player, isCurrent, shouldPlay, isMuted) {
        val p = player ?: return@LaunchedEffect
        if (shouldPlay) {
            p.volume = if (isMuted) 0f else 1f
            p.play()
        } else {
            p.pause()
            if (!isCurrent) {
                p.volume = 0f
                p.seekTo(0)
                progress = 0f
            }
        }
    }

    // Scrubber position, polled only for the reel on screen.
    LaunchedEffect(player, isCurrent, isSeeking) {
        val p = player ?: return@LaunchedEffect
        while (isActive && isCurrent && !isSeeking) {
            val duration = p.duration
            progress = if (duration > 0) p.currentPosition.toFloat() / duration else 0f
            delay(250)
        }
    }

    LaunchedEffect(heartBursts) {
        if (heartBursts == 0) return@LaunchedEffect
        showHeart = true
        delay(700)
        showHeart = false
    }

    val authorName = profile?.bestName ?: (reel.note.pubkey.take(8) + "…")
    // The gesture detector below is installed once; these keep it reading the
    // page's current values rather than the ones from its first composition.
    val currentIsLiked by rememberUpdatedState(isLiked)
    val currentOnLike by rememberUpdatedState(onLike)

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .semantics { contentDescription = "Video by $authorName" },
    ) {
        val screenAspect = if (maxHeight.value > 0f) maxWidth.value / maxHeight.value else 0f
        val fills = Reel.fillsScreen(learnedAspect ?: reel.aspectRatio, screenAspect)

        player?.let { p ->
            VideoSurface(
                player = p,
                resizeMode = if (fills) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT,
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (!hasFrame && reel.posterUrl != null) {
            AsyncImage(
                model = reel.posterUrl,
                contentDescription = null,
                contentScale = if (fills) ContentScale.Crop else ContentScale.Fit,
                onSuccess = { state ->
                    val size = state.painter.intrinsicSize
                    if (learnedAspect == null && size.width > 0f && size.height > 0f) {
                        learnedAspect = size.width / size.height
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }

        // Tap to pause, double-tap to like. Under the chrome, so the buttons
        // still get their own taps.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { if (player != null) userPaused = !userPaused },
                        onDoubleTap = {
                            if (!currentIsLiked) currentOnLike()
                            heartBursts++
                        },
                    )
                },
        )

        AnimatedVisibility(
            visible = userPaused,
            enter = fadeIn(Motion.control()),
            exit = fadeOut(Motion.control()),
            modifier = Modifier.align(Alignment.Center),
        ) {
            Icon(
                imageVector = NostrVaultIcons.PlayArrow,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.9f),
                modifier = Modifier.size(72.dp),
            )
        }

        AnimatedVisibility(
            visible = showHeart,
            enter = scaleIn(Motion.pop(), initialScale = 0.5f) + fadeIn(Motion.fade()),
            exit = fadeOut(Motion.fade()),
            modifier = Modifier.align(Alignment.Center),
        ) {
            Icon(
                imageVector = NostrVaultIcons.HeartFilled,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(110.dp),
            )
        }

        if (failed) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.align(Alignment.Center),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Alert,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(32.dp),
                )
                Text(
                    text = "This video can't be played",
                    color = Color.White.copy(alpha = 0.85f),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }

        // ── Chrome ──
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)))),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(top = 80.dp, bottom = bottomInset + 6.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.Bottom,
                    modifier = Modifier.padding(horizontal = 14.dp),
                ) {
                    ReelDetails(
                        reel = reel,
                        profile = profile,
                        profiles = profiles,
                        authorName = authorName,
                        captionExpanded = captionExpanded,
                        onToggleCaption = { captionExpanded = !captionExpanded },
                        onProfile = onProfile,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        RailButton(
                            icon = if (isLiked) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
                            tint = if (isLiked) Color(0xFFFF3B30) else Color.White,
                            label = if (isLiked) "Liked" else "Like",
                            onClick = onLike,
                        )
                        RailButton(NostrVaultIcons.Reply, label = "Reply", onClick = onReply)
                        RailButton(NostrVaultIcons.Chat, label = "Open thread", onClick = onOpenNote)
                        RailButton(NostrVaultIcons.Share, label = "Share", onClick = onShare)
                        RailButton(
                            icon = if (isMuted) NostrVaultIcons.VolumeOff else NostrVaultIcons.VolumeUp,
                            label = if (isMuted) "Unmute" else "Mute",
                            onClick = onToggleMute,
                        )
                    }
                }

                player?.let { p ->
                    ThinSeekBar(
                        progress = progress,
                        onSeekStart = { isSeeking = true },
                        onSeek = { fraction ->
                            progress = fraction
                            p.seekTo((fraction * p.duration.coerceAtLeast(1L)).toLong())
                        },
                        onSeekEnd = { isSeeking = false },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 10.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun ReelDetails(
    reel: Reel,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile>,
    authorName: String,
    captionExpanded: Boolean,
    onToggleCaption: () -> Unit,
    onProfile: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier.widthIn(max = 520.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .clickable(onClick = onProfile)
                .semantics { contentDescription = "$authorName's profile" },
        ) {
            AvatarImage(
                url = profile?.pictureURL,
                pubkey = reel.note.pubkey,
                size = 32.dp,
                displayName = profile?.bestName,
                modifier = Modifier.border(1.dp, Color.White.copy(alpha = 0.8f), CircleShape),
            )
            Text(
                text = authorName,
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Text(
                text = "· " + formatTimestamp(reel.createdAt),
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 13.sp,
                maxLines = 1,
            )
        }

        reel.title?.let { title ->
            Text(
                text = title,
                color = Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (reel.caption.isNotEmpty()) {
            val caption = remember(reel.caption, profiles) { NostrMentions.toPlainText(reel.caption, profiles) }
            Text(
                text = caption,
                color = Color.White,
                fontSize = 14.sp,
                maxLines = if (captionExpanded) 12 else 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable(onClick = onToggleCaption),
            )
        }
    }
}

@Composable
private fun RailButton(
    icon: ImageVector,
    label: String,
    tint: Color = Color.White,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick, modifier = Modifier.size(48.dp)) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = tint,
            modifier = Modifier.size(28.dp),
        )
    }
}

@Composable
private fun ReelsEmptyState(
    followSetIsEmpty: Boolean,
    loadFailed: Boolean,
    scope: ReelsScope,
    onShowGlobal: () -> Unit,
    onRetry: () -> Unit,
) {
    val following = scope == ReelsScope.FOLLOWING
    val title = when {
        followSetIsEmpty -> "You aren't following anyone yet"
        loadFailed -> "Could not reach any relay"
        following -> "No videos from your follows"
        else -> "No videos found"
    }
    val message = when {
        followSetIsEmpty -> "Switch to Global to see everyone's videos."
        loadFailed -> "Reels come from relays, so this one needs a connection."
        following -> "Nobody you follow has posted a video recently."
        else -> "Nothing playable came back from your relays."
    }
    val offerGlobal = followSetIsEmpty || (following && !loadFailed)

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.padding(horizontal = 40.dp),
    ) {
        Icon(
            imageVector = if (loadFailed) NostrVaultIcons.Alert else NostrVaultIcons.Reels,
            contentDescription = null,
            tint = Color.White.copy(alpha = 0.7f),
            modifier = Modifier.size(40.dp),
        )
        Text(title, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Text(message, color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp, textAlign = TextAlign.Center)
        TextButton(onClick = if (offerGlobal) onShowGlobal else onRetry) {
            Text(
                text = if (offerGlobal) "Show everyone's videos" else "Try again",
                color = LocalNostrVaultColors.current.primaryLight,
            )
        }
    }
}
