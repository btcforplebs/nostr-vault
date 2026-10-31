package com.nostrvault.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.nostrvault.ui.notification.LocalNotificationManager
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.compose.ui.text.font.FontWeight
import com.nostrvault.service.MediaCacheService
import com.nostrvault.ui.components.AudioPlayer
import com.nostrvault.ui.components.VideoPiPBridge
import com.nostrvault.ui.components.VideoControls
import com.nostrvault.ui.components.VideoPlayer
import com.nostrvault.ui.components.ZoomableBox
import com.nostrvault.ui.components.ZoomableImage
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max

/**
 * Full-screen media viewer with horizontal paging, pinch-to-zoom,
 * drag-to-dismiss, and single-ExoPlayer memory guard.
 *
 * Reads the current media list from [MediaGalleryBridge].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaViewerScreen(
    initialIndex: Int,
    onBack: () -> Unit,
    onNoteClick: (String) -> Unit = {},
    autoplayVideos: Boolean = true,
    viewModel: MediaViewerViewModel = hiltViewModel(),
) {
    val items = remember { MediaGalleryBridge.currentItems }
    val context = LocalContext.current
    val lane = LocalNotificationManager.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    val mirrorStatus by viewModel.mirrorStatus.collectAsState()
    val mirrorPresence by viewModel.mirrorPresence.collectAsState()
    val sourceVersion by viewModel.sourceVersion.collectAsState()
    val savingSha by viewModel.savingSha.collectAsState()
    val cachingSha by viewModel.cachingSha.collectAsState()
    val isCheckingMirrors by viewModel.isCheckingMirrors.collectAsState()
    val pushingSha by viewModel.pushingSha.collectAsState()
    val deleteLeftover by viewModel.deleteLeftover.collectAsState()
    // Hide all viewer chrome while the activity is shown in a PiP window
    val isInPiP by VideoPiPBridge.isInPiP.collectAsState()
    var showMirrorSheet by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<DeleteScope?>(null) }

    if (items.isEmpty()) {
        LaunchedEffect(Unit) { onBack() }
        return
    }

    val safeIndex = initialIndex.coerceIn(0, items.lastIndex)
    val pagerState = rememberPagerState(
        initialPage = safeIndex,
        pageCount = { items.size },
    )

    // Show the mirror count for the visible page: a saved answer if one is
    // under a day old, else the servers are asked.
    LaunchedEffect(pagerState.currentPage) {
        items.getOrNull(pagerState.currentPage)?.let { viewModel.checkMirrors(it.sha256, force = false) }
        // A delete's leftover names one file; it doesn't follow the swipe.
        viewModel.dismissDeleteLeftover()
    }

    // Drag-to-dismiss state
    val dragOffsetY = remember { Animatable(0f) }
    var currentScale by remember { mutableFloatStateOf(1f) }

    // Derived visual properties matching iOS formulas
    val backgroundAlpha by remember {
        derivedStateOf {
            (0.9f * (1f - abs(dragOffsetY.value) / 300f)).coerceIn(0f, 0.9f)
        }
    }
    val contentScale by remember {
        derivedStateOf {
            max(0.8f, 1f - abs(dragOffsetY.value) / 1000f)
        }
    }
    val overlayAlpha by remember {
        derivedStateOf {
            (1f - abs(dragOffsetY.value) / 100f).coerceIn(0f, 1f)
        }
    }

    // Dismiss threshold in pixels (120dp)
    val dismissThresholdPx = with(density) { 120.dp.toPx() }

    // Accumulated vertical drag for the page's drag-to-dismiss
    var accumulatedDragY by remember { mutableFloatStateOf(0f) }
    val onVerticalDrag: (Float) -> Unit = { deltaY ->
        if (currentScale <= 1.05f) {
            accumulatedDragY += deltaY
            scope.launch { dragOffsetY.snapTo(accumulatedDragY) }
        }
    }
    val onVerticalDragEnd: () -> Unit = {
        if (abs(accumulatedDragY) > dismissThresholdPx) {
            onBack()
        } else {
            scope.launch { dragOffsetY.animateTo(0f, Motion.snapBack()) }
        }
        accumulatedDragY = 0f
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = backgroundAlpha)),
    ) {
        HorizontalPager(
            state = pagerState,
            userScrollEnabled = currentScale <= 1.05f,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    translationY = dragOffsetY.value
                    scaleX = contentScale
                    scaleY = contentScale
                },
        ) { page ->
            val item = items[page]

            if (item.isVideo || item.isAudio) {
                // The same gestures as a photo (iOS): drag to close, and
                // pinch / double-tap zoom on a video. A single tap shows or
                // hides the player's controls, which zooming in hides.
                val videoControls = remember(item.displayUrl) { VideoControls() }
                ZoomableBox(
                    zoomable = item.isVideo && !isInPiP,
                    onScaleChanged = { newScale ->
                        currentScale = newScale
                        videoControls.zoomed(newScale)
                    },
                    onTap = if (item.isVideo && !isInPiP) videoControls::tap else null,
                    onVerticalDrag = onVerticalDrag,
                    onVerticalDragEnd = { onVerticalDragEnd() },
                    modifier = Modifier.fillMaxSize(),
                ) {
                    // Only create ExoPlayer for the currently visible page
                    // to keep memory usage at one instance (~10-15MB).
                    if (page == pagerState.currentPage) {
                        val mediaUri = item.localFile?.toUri()?.toString() ?: item.displayUrl
                        if (item.isAudio) {
                            AudioPlayer(
                                uri = mediaUri,
                                fileName = audioFileName(item.displayUrl, item.sha256),
                                modifier = Modifier.fillMaxSize(),
                                autoplay = autoplayVideos,
                            )
                        } else {
                            VideoPlayer(
                                uri = mediaUri,
                                modifier = Modifier.fillMaxSize(),
                                autoplay = autoplayVideos,
                                controls = videoControls.shown,
                            )
                        }
                    } else {
                        // Static thumbnail placeholder for off-screen video pages
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxSize()
                                .background(Color.Black),
                        ) {
                            AsyncImage(
                                model = ImageRequest.Builder(context)
                                    .data(item.localFile ?: item.displayUrl)
                                    .crossfade(true)
                                    .build(),
                                contentDescription = null,
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize(),
                            )
                            Icon(
                                imageVector = NostrVaultIcons.PlayCircle,
                                contentDescription = "Video",
                                tint = Color.White.copy(alpha = 0.85f),
                                modifier = Modifier.size(48.dp),
                            )
                        }
                    }
                }
            } else {
                ZoomableImage(
                    model = item.localFile ?: item.displayUrl,
                    // The Vault lists the owner's media: read from their own vault when a URL fails.
                    meshAuthor = com.nostrvault.fips.FipsMediaRouter.ownerHex().takeIf { it.isNotEmpty() },
                    contentDescription = null,
                    onScaleChanged = { newScale ->
                        currentScale = newScale
                    },
                    onVerticalDrag = onVerticalDrag,
                    onVerticalDragEnd = { onVerticalDragEnd() },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        // Close button (fades during drag, hidden in PiP)
        if (!isInPiP) {
            IconButton(
                onClick = onBack,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(8.dp)
                    .graphicsLayer { alpha = overlayAlpha },
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Dismiss,
                    contentDescription = "Close",
                    tint = Color.White,
                )
            }
        }

        // Top-right actions (fade during drag, hidden in PiP)
        val menuItem = items.getOrNull(pagerState.currentPage)
        if (!isInPiP) Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(8.dp)
                .graphicsLayer { alpha = overlayAlpha },
        ) {
            if (menuItem?.noteId != null) {
                IconButton(onClick = { onNoteClick(menuItem.noteId) }) {
                    Icon(NostrVaultIcons.Document, contentDescription = "View Note", tint = Color.White)
                }
            }
            IconButton(onClick = { menuItem?.let { viewModel.saveToGallery(it) } }) {
                Icon(NostrVaultIcons.Import, contentDescription = "Save to gallery", tint = Color.White)
            }
            if (menuItem != null && menuItem.sha256.isNotEmpty()) {
                IconButton(onClick = {
                    val url = viewModel.blossomLink(menuItem)
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(ClipData.newPlainText("Blossom URL", url))
                    lane.showFeedback("Link copied", NostrVaultIcons.LinkIcon)
                }) {
                    Icon(NostrVaultIcons.Copy, contentDescription = "Copy link", tint = Color.White)
                }
                IconButton(onClick = { pendingDelete = DeleteScope.MIRRORS }) {
                    Icon(NostrVaultIcons.Cloud, contentDescription = "Delete from media servers", tint = Color(0xFFE53935))
                }
                IconButton(onClick = { pendingDelete = DeleteScope.EVERYWHERE }) {
                    Icon(NostrVaultIcons.Delete, contentDescription = "Delete everywhere", tint = Color(0xFFE53935))
                }
            }
        }

        // Mirror status + page indicator at the bottom
        val currentItem = items.getOrNull(pagerState.currentPage)
        val isPushing = pushingSha != null && pushingSha == currentItem?.sha256
        val mirroredCount = mirrorStatus.values.count { it }
        val total = viewModel.totalMirrors
        val mirrorColor = when {
            isCheckingMirrors -> Color.White.copy(alpha = 0.5f)
            total == 0 -> Color.Gray
            mirroredCount == total -> Color(0xFF4CAF50)
            mirroredCount > 0 -> Color(0xFFFF9800)
            else -> Color.Gray
        }
        val source = currentItem?.let { item ->
            produceState<MediaCacheService.MediaSource?>(null, item.sha256, item.displayUrl, sourceVersion) {
                value = viewModel.source(item)
            }.value
        }
        if (!isInPiP) Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 4.dp)
                .graphicsLayer { alpha = overlayAlpha },
        ) {
            if (currentItem != null && source != null) {
                MediaSourceRow(
                    source = source,
                    saving = savingSha == viewerItemKey(currentItem),
                    caching = cachingSha == viewerItemKey(currentItem),
                    onSaveToVault = { viewModel.saveToVault(currentItem) },
                    onCacheLocally = { viewModel.cacheLocally(currentItem) },
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { showMirrorSheet = true }) {
                    if (isPushing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            color = Color.White.copy(alpha = 0.6f),
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Pushing to mirrors…", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
                    } else if (isCheckingMirrors) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            color = Color.White.copy(alpha = 0.6f),
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Checking mirrors…", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
                    } else {
                        Icon(
                            imageVector = NostrVaultIcons.Cloud,
                            contentDescription = null,
                            tint = mirrorColor,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = if (total == 0) "No mirrors configured" else "$mirroredCount / $total mirrors",
                            color = mirrorColor,
                            fontSize = 12.sp,
                        )
                    }
                }
                // Like iOS: offer an upload only when some server lacks the file.
                // Only a file on the phone can be pushed (iOS: the .blossom source).
                if (currentItem != null && currentItem.sha256.isNotEmpty() && source == MediaCacheService.MediaSource.BLOSSOM &&
                    !isCheckingMirrors && pushingSha == null && total > 0 && mirroredCount < total
                ) {
                    TextButton(onClick = { viewModel.pushToMirrors(currentItem.sha256) }) {
                        Icon(
                            imageVector = NostrVaultIcons.ArrowUp,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(4.dp))
                        Text("Mirror", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            // Like iOS: only for a file on the phone that some server lacks.
            val unreachable = currentItem?.takeIf { source == MediaCacheService.MediaSource.BLOSSOM && it.sha256.isNotEmpty() }
                ?.let { viewModel.backupSummary(it.sha256, mirrorPresence) }
                ?.takeIf { it.needsMirror }?.unreachable ?: 0
            if (unreachable > 0) {
                Text(unreachableServersText(unreachable), color = Color.White.copy(alpha = 0.6f), fontSize = 11.sp)
            }
            if (items.size > 1) {
                Text(
                    text = "${pagerState.currentPage + 1} / ${items.size}",
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 14.sp,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            } else {
                Spacer(Modifier.height(8.dp))
            }
        }

        if (showMirrorSheet && currentItem != null) {
            MirrorStatusSheet(
                sha256 = currentItem.sha256,
                mirrorStatus = mirrorStatus,
                isLoading = isCheckingMirrors,
                totalMirrors = total,
                onDismiss = { showMirrorSheet = false },
                onPushToMirrors = { viewModel.pushToMirrors(currentItem.sha256) },
            )
        }

        // A delete that left copies behind stays up until tapped, so it can't
        // be missed; the viewer stays open with it.
        val leftover = deleteLeftover
        if (leftover != null && !isInPiP) {
            DeleteLeftoverBanner(
                message = leftover,
                onDismiss = { viewModel.dismissDeleteLeftover() },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 64.dp, start = 24.dp, end = 24.dp),
            )
        }

        // Confirm destructive deletes.
        pendingDelete?.let { scope ->
            if (currentItem == null) {
                pendingDelete = null
                return@let
            }
            val postCount = remember(scope, currentItem.sha256) {
                if (scope == DeleteScope.EVERYWHERE) viewModel.postsUsing(currentItem.sha256) else 0
            }
            fun confirm(deletePosts: Boolean) {
                when (scope) {
                    DeleteScope.MIRRORS -> viewModel.deleteFromMirrors(currentItem, sticky = true)
                    DeleteScope.EVERYWHERE -> viewModel.deleteEverywhere(currentItem, sticky = true, deletePosts = deletePosts) { allGone ->
                        if (allGone) onBack()
                    }
                }
                pendingDelete = null
            }
            DeleteBlobConfirmDialog(
                scope = scope,
                postCount = postCount,
                onConfirm = { confirm(deletePosts = false) },
                onConfirmWithPosts = { confirm(deletePosts = true) },
                onDismiss = { pendingDelete = null },
            )
        }
    }
}

/** Derive a display filename for an audio blob from its URL or sha256. */
private fun audioFileName(displayUrl: String, sha256: String): String {
    val fromUrl = displayUrl.substringAfterLast('/').substringBefore('?')
        .takeIf { it.isNotBlank() && it.contains('.') }
    return fromUrl ?: ("Audio " + sha256.take(8))
}
