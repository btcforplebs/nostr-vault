package com.nostrvault.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaSaveService
import com.nostrvault.service.NostrService
import com.nostrvault.service.deleteEverywhereLeftover
import com.nostrvault.ui.components.AudioPlayer
import com.nostrvault.ui.components.VideoPiPBridge
import com.nostrvault.ui.components.VideoPlayer
import com.nostrvault.ui.components.ZoomableImage
import com.nostrvault.ui.notification.ErrorStyle
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import kotlin.math.abs
import kotlin.math.max

/**
 * The link to share for a Blossom item: its own URL when it has one, otherwise
 * the first public mirror + sha256. Never a path on this phone.
 */
internal fun publicBlossomLink(item: BlossomMediaItem, mirrors: List<String>): String {
    if (item.displayUrl.startsWith("http")) return item.displayUrl
    val mirror = mirrors.firstOrNull { !it.contains("localhost") && !it.contains("127.0.0.1") }
    return if (mirror != null) "$mirror/${item.sha256}" else item.displayUrl
}

@HiltViewModel
class MediaViewerViewModel @Inject constructor(
    private val mediaSaveService: MediaSaveService,
    private val notificationManager: NotificationManager,
    private val blossomService: BlossomService,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {

    private val _mirrorStatus = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val mirrorStatus = _mirrorStatus.asStateFlow()

    private val _isCheckingMirrors = MutableStateFlow(false)
    val isCheckingMirrors = _isCheckingMirrors.asStateFlow()

    val totalMirrors: Int
        get() = configStore.config.value.activeBlossomMirrors.size

    /** The blob the viewer is showing, so a late push result doesn't re-check another page. */
    private var currentSha: String? = null

    fun checkMirrors(sha256: String) {
        currentSha = sha256
        viewModelScope.launch {
            _isCheckingMirrors.value = true
            _mirrorStatus.value = emptyMap()
            try {
                val status = withContext(Dispatchers.IO) {
                    blossomService.checkMirrorStatus(sha256)
                }
                _mirrorStatus.value = status
            } finally {
                _isCheckingMirrors.value = false
            }
        }
    }

    /** The blob being pushed right now, or null. */
    private val _pushingSha = MutableStateFlow<String?>(null)
    val pushingSha = _pushingSha.asStateFlow()

    /**
     * Upload the blob to the servers the last check found without it (all of
     * them when nothing has been checked yet), then report what actually
     * happened and re-check.
     */
    fun pushToMirrors(sha256: String) {
        if (_pushingSha.value != null) return
        // The status map belongs to the page on screen, which is this blob.
        val missing = if (currentSha == sha256) _mirrorStatus.value.filterValues { !it }.keys else emptySet()
        viewModelScope.launch {
            _pushingSha.value = sha256
            val result = try {
                withContext(Dispatchers.IO) {
                    blossomService.pushLocalToMirrors(sha256, only = missing.ifEmpty { null })
                }
            } finally {
                _pushingSha.value = null
            }
            announcePush(result)
            if (currentSha == sha256) checkMirrors(sha256)
        }
    }

    private fun announcePush(result: BlossomService.MirrorPushResult) {
        when (result) {
            is BlossomService.MirrorPushResult.AllAccepted -> notificationManager.showToast(result.message)
            is BlossomService.MirrorPushResult.Partial -> notificationManager.showError(result.message, ErrorStyle.WARNING)
            else -> notificationManager.showError(result.message)
        }
    }

    /**
     * What a delete left behind, shown in the viewer until tapped. A failure
     * that timed out with the viewer was gone before anyone could read it.
     */
    private val _deleteLeftover = MutableStateFlow<String?>(null)
    val deleteLeftover = _deleteLeftover.asStateFlow()

    fun dismissDeleteLeftover() {
        _deleteLeftover.value = null
    }

    /**
     * Report a failed delete: in the viewer's own banner when [sticky], so it
     * stays until tapped, otherwise as a longer-lived warning pill.
     */
    private fun reportLeftover(message: String, sticky: Boolean) {
        if (sticky) _deleteLeftover.value = message
        else notificationManager.showError(message, ErrorStyle.WARNING, autoDismissMs = 6_000L)
    }

    /** Delete the blob from all external mirrors; the local copy is kept. [onDone] runs after. */
    fun deleteFromMirrors(item: BlossomMediaItem, sticky: Boolean = false, onDone: () -> Unit = {}) {
        if (item.sha256.isEmpty()) {
            notificationManager.showError("No hash for this item")
            return
        }
        _deleteLeftover.value = null
        viewModelScope.launch {
            val report = withContext(Dispatchers.IO) { blossomService.deleteFromMirrors(item.sha256) }
            when {
                report.allDeleted -> notificationManager.showToast("Deleted from mirrors")
                report.failed.isEmpty() -> notificationManager.showError("No mirrors to delete from")
                else -> reportLeftover(deleteEverywhereLeftover(localDeleted = true, mirrors = report)!!, sticky)
            }
            checkMirrors(item.sha256)
            onDone()
        }
    }

    /** How many of your loaded posts link [sha256]; Delete everywhere offers to delete them too. */
    fun postsUsing(sha256: String): Int =
        if (sha256.isEmpty()) 0 else nostrService.ownEvents(referencingBlob = sha256).size

    /**
     * Delete everywhere (local + mirrors) and report each place. [onDone] gets
     * true only when nothing is left anywhere, so the viewer can close; on a
     * partial delete it stays open with the places named. With [deletePosts],
     * first ask relays to delete your posts that link it (iOS "Delete file and post").
     */
    fun deleteEverywhere(
        item: BlossomMediaItem,
        sticky: Boolean = false,
        deletePosts: Boolean = false,
        onDone: (allGone: Boolean) -> Unit,
    ) {
        if (item.sha256.isEmpty()) {
            notificationManager.showError("No hash for this item")
            return
        }
        _deleteLeftover.value = null
        viewModelScope.launch {
            if (deletePosts) nostrService.deleteOwnEvents(referencingBlob = item.sha256)
            val (localOk, report) = withContext(Dispatchers.IO) {
                val local = async { blossomService.deleteFromLocal(item.sha256) }
                val mirrors = async { blossomService.deleteFromMirrors(item.sha256) }
                local.await() to mirrors.await()
            }
            val leftover = deleteEverywhereLeftover(localDeleted = localOk, mirrors = report)
            if (leftover == null) {
                notificationManager.showToast("Deleted everywhere")
            } else {
                reportLeftover(leftover, sticky)
                // The cloud badge caches each server's answer for the session;
                // ask again so it stops showing the pre-delete count.
                checkMirrors(item.sha256)
            }
            onDone(leftover == null)
        }
    }

    /** Returns the best public Blossom URL for [item] — external mirror preferred over local. */
    fun blossomLink(item: BlossomMediaItem): String =
        publicBlossomLink(item, configStore.config.value.activeBlossomMirrors)

    fun saveToGallery(item: BlossomMediaItem) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                if (item.localFile != null) {
                    mediaSaveService.saveToGallery(item.localFile, item.mimeType)
                } else {
                    mediaSaveService.saveToGallery(item.displayUrl, item.mimeType)
                }
            }
            if (result.isSuccess) {
                notificationManager.showToast("Saved to gallery")
            } else {
                notificationManager.showError("Save failed: ${result.exceptionOrNull()?.message}")
            }
        }
    }
}

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
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    val mirrorStatus by viewModel.mirrorStatus.collectAsState()
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

    // Check mirrors whenever the visible page changes
    LaunchedEffect(pagerState.currentPage) {
        items.getOrNull(pagerState.currentPage)?.let { viewModel.checkMirrors(it.sha256) }
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

    // Accumulated vertical drag for ZoomableImage callback
    var accumulatedDragY by remember { mutableFloatStateOf(0f) }

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
            } else {
                ZoomableImage(
                    model = item.localFile ?: item.displayUrl,
                    contentDescription = null,
                    onScaleChanged = { newScale ->
                        currentScale = newScale
                    },
                    onVerticalDrag = { deltaY ->
                        if (currentScale <= 1.05f) {
                            accumulatedDragY += deltaY
                            scope.launch {
                                dragOffsetY.snapTo(accumulatedDragY)
                            }
                        }
                    },
                    onVerticalDragEnd = {
                        if (abs(accumulatedDragY) > dismissThresholdPx) {
                            onBack()
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
                    Toast.makeText(context, "Link copied", Toast.LENGTH_SHORT).show()
                }) {
                    Icon(NostrVaultIcons.Copy, contentDescription = "Copy link", tint = Color.White)
                }
                IconButton(onClick = { pendingDelete = DeleteScope.MIRRORS }) {
                    Icon(NostrVaultIcons.Cloud, contentDescription = "Delete from mirrors", tint = Color(0xFFE53935))
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
        if (!isInPiP) Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 4.dp)
                .graphicsLayer { alpha = overlayAlpha },
        ) {
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
                if (currentItem != null && currentItem.sha256.isNotEmpty() &&
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

/** Red tap-to-dismiss banner naming where a delete left the file. Port of the iOS viewer's failure banner. */
@Composable
private fun DeleteLeftoverBanner(message: String, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onDismiss,
        shape = RoundedCornerShape(18.dp),
        color = Color(0xCCE53935),
        contentColor = Color.White,
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(vertical = 12.dp, horizontal = 16.dp),
        ) {
            Icon(NostrVaultIcons.Alert, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(
                message,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(NostrVaultIcons.Dismiss, contentDescription = "Dismiss", modifier = Modifier.size(12.dp).graphicsLayer { alpha = 0.7f })
        }
    }
}

/**
 * Confirmation for a destructive blob delete; shared by the viewer and the Media tab's long-press menu.
 * When [postCount] of your posts use the blob, Delete everywhere also offers [onConfirmWithPosts]
 * ("Delete file and post"), so no post is left showing a dead image. Wording matches iOS
 * `confirmMediaDelete` (DestructiveConfirmation.swift).
 */
@Composable
internal fun DeleteBlobConfirmDialog(
    scope: DeleteScope,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    postCount: Int = 0,
    onConfirmWithPosts: (() -> Unit)? = null,
) {
    val title: String
    val body: String
    val confirmLabel: String
    when (scope) {
        DeleteScope.MIRRORS -> {
            title = "Delete from mirrors?"
            body = "Removes this blob from all external Blossom mirrors. Your local copy is kept."
            confirmLabel = "Delete from mirrors"
        }
        DeleteScope.EVERYWHERE -> {
            title = "Delete everywhere?"
            body = "Permanently removes this blob from your local Blossom store and all external mirrors. This cannot be undone."
            confirmLabel = "Delete everywhere"
        }
    }
    val offerPosts = scope == DeleteScope.EVERYWHERE && postCount > 0 && onConfirmWithPosts != null
    val message = if (offerPosts) body + deleteBlobPostsNote(postCount) else body
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            if (offerPosts && onConfirmWithPosts != null) {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = onConfirmWithPosts) {
                        Text(deleteBlobWithPostsLabel(postCount), color = Color(0xFFE53935))
                    }
                    TextButton(onClick = onConfirm) {
                        Text("Delete file only", color = Color(0xFFE53935))
                    }
                }
            } else {
                TextButton(onClick = onConfirm) {
                    Text(confirmLabel, color = Color(0xFFE53935))
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/** iOS: "Delete file and post" / "Delete file and N posts". */
internal fun deleteBlobWithPostsLabel(postCount: Int): String =
    if (postCount == 1) "Delete file and post" else "Delete file and $postCount posts"

/** Appended to the Delete everywhere message when your posts use the blob (iOS wording). */
internal fun deleteBlobPostsNote(postCount: Int): String =
    if (postCount == 1) {
        " One of your posts uses it and will show a broken image unless you delete that post too."
    } else {
        " $postCount of your posts use it and will show a broken image unless you delete them too."
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MirrorStatusSheet(
    sha256: String,
    mirrorStatus: Map<String, Boolean>,
    isLoading: Boolean,
    totalMirrors: Int,
    onDismiss: () -> Unit,
    onPushToMirrors: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
        ) {
            Text("Blossom Mirrors", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = PrimaryText)
            Spacer(Modifier.height(2.dp))
            Text(
                text = sha256.take(16) + "…",
                fontSize = 11.sp,
                color = TertiaryText,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(Modifier.height(16.dp))

            when {
                isLoading -> {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    ) {
                        CircularProgressIndicator()
                    }
                }
                totalMirrors == 0 -> {
                    Text(
                        "No mirrors configured. Add Blossom mirrors in Settings.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                    )
                }
                else -> {
                    mirrorStatus.entries.sortedBy { it.key }.forEach { (mirror, available) ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 10.dp),
                        ) {
                            Icon(
                                imageVector = if (available) NostrVaultIcons.Check else NostrVaultIcons.Dismiss,
                                contentDescription = null,
                                tint = if (available) Color(0xFF4CAF50) else Color(0xFFE53935),
                                modifier = Modifier.size(20.dp),
                            )
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                val host = runCatching { java.net.URL(mirror).host }.getOrNull() ?: mirror
                                Text(host, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                Text(
                                    mirror,
                                    color = TertiaryText,
                                    fontSize = 11.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = if (available) "Available" else "Not Found",
                                color = if (available) Color(0xFF4CAF50) else SecondaryText,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                    }

                    val missingCount = mirrorStatus.values.count { !it }
                    if (missingCount > 0) {
                        Spacer(Modifier.height(16.dp))
                        Button(
                            onClick = { onPushToMirrors(); onDismiss() },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(NostrVaultIcons.ArrowUp, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Push to Missing Mirrors")
                        }
                    }
                }
            }
        }
    }
}

/** Derive a display filename for an audio blob from its URL or sha256. */
private fun audioFileName(displayUrl: String, sha256: String): String {
    val fromUrl = displayUrl.substringAfterLast('/').substringBefore('?')
        .takeIf { it.isNotBlank() && it.contains('.') }
    return fromUrl ?: ("Audio " + sha256.take(8))
}
