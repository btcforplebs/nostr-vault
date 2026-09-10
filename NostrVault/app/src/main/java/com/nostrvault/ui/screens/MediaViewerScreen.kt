package com.nostrvault.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
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
import com.nostrvault.ui.components.VideoPlayer
import com.nostrvault.ui.components.ZoomableImage
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

@HiltViewModel
class MediaViewerViewModel @Inject constructor(
    private val mediaSaveService: MediaSaveService,
    private val notificationManager: NotificationManager,
    private val blossomService: BlossomService,
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _mirrorStatus = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val mirrorStatus = _mirrorStatus.asStateFlow()

    private val _isCheckingMirrors = MutableStateFlow(false)
    val isCheckingMirrors = _isCheckingMirrors.asStateFlow()

    val totalMirrors: Int
        get() = configStore.config.value.activeBlossomMirrors.size

    fun checkMirrors(sha256: String) {
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

    fun pushToMirrors(sha256: String) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                blossomService.pushLocalToMirrors(sha256)
            }
            notificationManager.showToast("Pushed to mirrors")
            checkMirrors(sha256)
        }
    }

    /** Delete the blob from all external mirrors; the local copy is kept. */
    fun deleteFromMirrors(item: BlossomMediaItem) {
        if (item.sha256.isEmpty()) {
            notificationManager.showError("No hash for this item")
            return
        }
        viewModelScope.launch {
            val count = withContext(Dispatchers.IO) { blossomService.deleteFromMirrors(item.sha256) }
            notificationManager.showToast(
                if (count > 0) "Deleted from $count mirror(s)" else "Not found on mirrors",
            )
            checkMirrors(item.sha256)
        }
    }

    /** Delete everywhere (local + mirrors), then invoke [onDeleted] so the viewer can dismiss. */
    fun deleteEverywhere(item: BlossomMediaItem, onDeleted: () -> Unit) {
        if (item.sha256.isEmpty()) {
            notificationManager.showError("No hash for this item")
            return
        }
        viewModelScope.launch {
            val (localOk, mirrorCount) = withContext(Dispatchers.IO) {
                val local = async { blossomService.deleteFromLocal(item.sha256) }
                val mirrors = async { blossomService.deleteFromMirrors(item.sha256) }
                local.await() to mirrors.await()
            }
            notificationManager.showToast(
                if (localOk || mirrorCount > 0) "Deleted everywhere" else "Nothing to delete",
            )
            onDeleted()
        }
    }

    /** Returns the best public Blossom URL for [item] — external mirror preferred over local. */
    fun blossomLink(item: BlossomMediaItem): String {
        if (item.displayUrl.startsWith("http")) return item.displayUrl
        val mirror = configStore.config.value.activeBlossomMirrors
            .firstOrNull { !it.contains("localhost") && !it.contains("127.0.0.1") }
        return if (mirror != null) "$mirror/${item.sha256}" else item.displayUrl
    }

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
                // to keep memory usage at one instance (~10-15MB). ExoPlayer
                // plays audio-only blobs too (the surface just stays black).
                if (page == pagerState.currentPage) {
                    val videoUri = item.localFile?.toUri()?.toString() ?: item.displayUrl
                    VideoPlayer(
                        uri = videoUri,
                        modifier = Modifier.fillMaxSize(),
                        autoplay = autoplayVideos,
                    )
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
                                dragOffsetY.animateTo(
                                    0f,
                                    spring(dampingRatio = 0.6f, stiffness = 400f),
                                )
                            }
                        }
                        accumulatedDragY = 0f
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        // Close button (fades during drag)
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

        // Top-right actions (fade during drag)
        val menuItem = items.getOrNull(pagerState.currentPage)
        Row(
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
        val mirroredCount = mirrorStatus.values.count { it }
        val total = viewModel.totalMirrors
        val mirrorColor = when {
            isCheckingMirrors -> Color.White.copy(alpha = 0.5f)
            total == 0 -> Color.Gray
            mirroredCount == total -> Color(0xFF4CAF50)
            mirroredCount > 0 -> Color(0xFFFF9800)
            else -> Color.Gray
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 4.dp)
                .graphicsLayer { alpha = overlayAlpha },
        ) {
            TextButton(onClick = { showMirrorSheet = true }) {
                if (isCheckingMirrors) {
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

        // Confirm destructive deletes.
        pendingDelete?.let { scope ->
            if (currentItem == null) {
                pendingDelete = null
                return@let
            }
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
            AlertDialog(
                onDismissRequest = { pendingDelete = null },
                title = { Text(title) },
                text = { Text(body) },
                confirmButton = {
                    TextButton(onClick = {
                        when (scope) {
                            DeleteScope.MIRRORS -> viewModel.deleteFromMirrors(currentItem)
                            DeleteScope.EVERYWHERE -> viewModel.deleteEverywhere(currentItem) { onBack() }
                        }
                        pendingDelete = null
                    }) {
                        Text(confirmLabel, color = Color(0xFFE53935))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
                },
            )
        }
    }
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
