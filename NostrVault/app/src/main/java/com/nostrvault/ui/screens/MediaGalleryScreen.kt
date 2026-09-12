package com.nostrvault.ui.screens

import android.net.Uri
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.*
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * Media gallery showing personal blossom content from local and external blossoms.
 * Port of MediaTabView.swift.
 */

@HiltViewModel
class MediaGalleryViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val statsService: StatsService,
    val mediaCacheService: MediaCacheService,
    private val blossomService: BlossomService,
    private val notificationManager: NotificationManager,
) : ViewModel() {

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _isUploading = MutableStateFlow(false)
    val isUploading = _isUploading.asStateFlow()

    private val _mediaItems = MutableStateFlow<List<BlossomMediaItem>>(emptyList())
    val mediaItems = _mediaItems.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    init {
        loadBlossomMedia()
    }

    fun refresh() {
        loadBlossomMedia()
    }

    private fun loadBlossomMedia() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                withContext(Dispatchers.IO) {
                    val items = mutableMapOf<String, BlossomMediaItem>()

                    // 1. Scan local blossom directory
                    loadLocalBlossomFiles(items)

                    // 2. Fetch from local relay via BUD-04
                    val pubkey = nostrService.ownerHexPubkey
                    if (pubkey.isNotEmpty()) {
                        try {
                            val localBlobs = statsService.fetchBlobList(pubkey)
                            mergeBlobs(items, localBlobs, source = null)
                        } catch (e: Exception) {
                            Log.w(TAG, "Local relay blob list failed: ${e.message}")
                        }

                        // 3. Fetch from external mirrors in parallel
                        val mirrors = configStore.config.value.activeBlossomMirrors
                        coroutineScope {
                            mirrors.map { mirror ->
                                async {
                                    try {
                                        fetchMirrorBlobList(mirror, pubkey) to mirror
                                    } catch (e: Exception) {
                                        Log.w(TAG, "Mirror list from $mirror failed: ${e.message}")
                                        null
                                    }
                                }
                            }.awaitAll().filterNotNull().forEach { (blobs, source) ->
                                mergeBlobs(items, blobs, source = source)
                            }
                        }
                    }

                    _mediaItems.value = items.values
                        .filter { it.isImage || it.isVideo || it.mimeType == null }
                        .sortedByDescending { it.uploaded ?: (it.lastModified?.div(1000)) ?: 0L }
                        .toList()
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    private fun loadLocalBlossomFiles(items: MutableMap<String, BlossomMediaItem>) {
        val config = configStore.config.value
        val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return
        if (!blossomDir.exists()) return

        blossomDir.listFiles()?.forEach { file ->
            if (!file.isFile) return@forEach
            val hash = file.nameWithoutExtension
            if (hash.length != 64 || !hash.all { it in "0123456789abcdef" }) return@forEach

            val fileType = statsService.detectFileType(file)

            items[hash] = BlossomMediaItem(
                sha256 = hash,
                displayUrl = file.absolutePath,
                localFile = file,
                mimeType = when (fileType) {
                    FileType.IMAGE -> "image"
                    FileType.VIDEO -> "video"
                    else -> null
                },
                size = file.length(),
                uploaded = null,
                lastModified = file.lastModified(),
                isLocal = true,
            )
        }
    }

    private fun mergeBlobs(
        items: MutableMap<String, BlossomMediaItem>,
        blobs: List<BlobDescriptor>,
        source: String?,
    ) {
        for (blob in blobs) {
            val hash = blob.sha256 ?: continue
            val existing = items[hash]
            if (existing != null) {
                // Merge metadata from server into existing local item
                items[hash] = existing.copy(
                    uploaded = blob.uploaded ?: existing.uploaded,
                    mimeType = blob.type ?: existing.mimeType,
                    size = blob.size ?: existing.size,
                )
            } else {
                // Remote-only item
                val url = blob.url ?: source?.let { "$it/$hash" } ?: continue
                items[hash] = BlossomMediaItem(
                    sha256 = hash,
                    displayUrl = url,
                    localFile = null,
                    mimeType = blob.type,
                    size = blob.size,
                    uploaded = blob.uploaded,
                    lastModified = null,
                    isLocal = false,
                )
            }
        }
    }

    private fun fetchMirrorBlobList(mirror: String, pubkey: String): List<BlobDescriptor> {
        val request = Request.Builder()
            .url("$mirror/list/$pubkey")
            .get()
            .build()

        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) return emptyList()

        val body = response.body?.string() ?: return emptyList()
        return json.decodeFromString<List<BlobDescriptor>>(body)
    }

    fun uploadMedia(uri: Uri, contentResolver: android.content.ContentResolver) {
        if (_isUploading.value) return
        viewModelScope.launch {
            _isUploading.value = true
            val filename = uri.lastPathSegment ?: "media"
            val uploadId = notificationManager.addUpload(filename)
            // Stream the picked media to a temp file instead of readBytes() — a
            // large video pulled fully into a ByteArray OOM-kills low-RAM devices
            // before the upload even starts. The File-based upload path streams
            // from disk (file.asRequestBody) end to end.
            var tempFile: File? = null
            try {
                tempFile = withContext(Dispatchers.IO) {
                    val f = File.createTempFile("upload_", null, mediaCacheService.cacheDirectory)
                    val copied = contentResolver.openInputStream(uri)?.use { input ->
                        f.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                        true
                    } ?: false
                    if (copied) f else { f.delete(); null }
                } ?: run {
                    notificationManager.markUploadFailed(uploadId, "Could not read file")
                    return@launch
                }

                val contentType = contentResolver.getType(uri) ?: "application/octet-stream"
                val sha256 = withContext(Dispatchers.IO) {
                    blossomService.computeSHA256(tempFile!!)
                }

                notificationManager.updateUploadProgress(uploadId, 0.3f)

                val resultUrl = withContext(Dispatchers.IO) {
                    // Vault save: local storage counts as success even if mirrors are down.
                    blossomService.uploadAndMirror(tempFile!!, sha256, contentType, allowLocalFallback = true)
                }

                notificationManager.updateUploadProgress(uploadId, 1.0f)

                if (resultUrl != null || blossomService.localBlossomURL() != null) {
                    notificationManager.markUploadSuccess(uploadId)
                    refresh()
                } else {
                    notificationManager.markUploadFailed(uploadId, "Upload failed")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Upload failed", e)
                notificationManager.markUploadFailed(uploadId, e.message ?: "Upload failed")
            } finally {
                tempFile?.let { withContext(NonCancellable + Dispatchers.IO) { it.delete() } }
                _isUploading.value = false
            }
        }
    }

    companion object {
        private const val TAG = "MediaGalleryVM"
    }
}

/** Lightweight bridge so MediaViewerScreen can access the gallery's current filtered media list. */
object MediaGalleryBridge {
    var currentItems: List<BlossomMediaItem> = emptyList()
}

data class BlossomMediaItem(
    val sha256: String,
    val displayUrl: String,
    val localFile: File?,
    val mimeType: String?,
    val size: Long?,
    val uploaded: Long?,
    val lastModified: Long?,
    val isLocal: Boolean,
    val noteId: String? = null,
) {
    val isVideo: Boolean get() = mimeType?.startsWith("video") == true
    val isImage: Boolean get() = mimeType?.startsWith("image") == true || mimeType == "image"
    val isAudio: Boolean get() = mimeType?.startsWith("audio") == true

    /** GIF detection by extension or mime type, matching iOS MediaGallery isGif. */
    val isGif: Boolean get() =
        mimeType?.contains("gif", ignoreCase = true) == true ||
            displayUrl.substringBefore('?').substringBefore('#')
                .substringAfterLast('.', "").equals("gif", ignoreCase = true)
}

data class MediaItem(val url: String, val noteId: String)

/** Scope for a pending destructive delete in MediaViewerScreen. */
enum class DeleteScope { MIRRORS, EVERYWHERE }

/** Media type filter matching iOS MediaTypeFilter. */
enum class MediaTypeFilter { ALL, PHOTO, VIDEO, GIF, OTHER }

/** Gallery layout mode. */
enum class MediaLayoutMode { GRID, LIST }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MediaGalleryScreen(
    onMediaClick: (Int) -> Unit,
    onNoteClick: (String) -> Unit,
    onBlossomClick: () -> Unit,
    feedService: FeedService,
    viewModel: MediaGalleryViewModel = hiltViewModel(),
) {
    val mediaItems by viewModel.mediaItems.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    var activeFilter by remember { mutableStateOf(MediaTypeFilter.ALL) }
    var layoutMode by remember { mutableStateOf(MediaLayoutMode.GRID) }
    val gridState = rememberLazyGridState()
    val listState = rememberLazyListState()

    // Scroll-direction detection → condense the bottom bar + Blossom FAB. Tracks
    // whichever container is currently shown (re-armed on the grid/list toggle).
    val isGrid = layoutMode == MediaLayoutMode.GRID
    ScrollCondenseEffect(
        scrollKey = isGrid,
        firstVisibleItemIndex = {
            if (isGrid) gridState.firstVisibleItemIndex else listState.firstVisibleItemIndex
        },
        firstVisibleItemScrollOffset = {
            if (isGrid) gridState.firstVisibleItemScrollOffset else listState.firstVisibleItemScrollOffset
        },
        setScrollingDown = feedService::setFeedScrollingDown,
    )
    var contextMenuTarget by remember { mutableStateOf<Int?>(null) }
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val mediaCacheService = viewModel.mediaCacheService

    val mediaPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        uri?.let { viewModel.uploadMedia(it, context.contentResolver) }
    }

    // A blob carries no note reference; the sha256 is the only join.
    //
    // Read from the persistent index rather than recomputed from the loaded
    // feed. Computed from the feed, the same file offered "Open Note" or did
    // not depending on how far the user had scrolled earlier in the session —
    // a state they cannot see and cannot predict. The index keeps every mapping
    // the feed has ever handed it, so the answer is a property of the blob.
    val noteIdByHash by feedService.blobNoteIndex.collectAsState()

    val filteredItems = remember(mediaItems, activeFilter) {
        mediaItems
            .filter { item ->
                when (activeFilter) {
                    MediaTypeFilter.ALL -> true
                    MediaTypeFilter.PHOTO -> item.isImage && !item.isGif
                    MediaTypeFilter.VIDEO -> item.isVideo
                    MediaTypeFilter.GIF -> item.isGif
                    MediaTypeFilter.OTHER -> !item.isImage && !item.isVideo
                }
            }
    }

    GlassScaffold(
        toolbar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    // Leading: media type filter icons
                    GlassPill {
                        MediaFilterIcon(
                            icon = NostrVaultIcons.GridLayout,
                            label = "All",
                            selected = activeFilter == MediaTypeFilter.ALL,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.ALL },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Media,
                            label = "Photos",
                            selected = activeFilter == MediaTypeFilter.PHOTO,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.PHOTO },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Video,
                            label = "Videos",
                            selected = activeFilter == MediaTypeFilter.VIDEO,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.VIDEO },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Gif,
                            label = "GIFs",
                            selected = activeFilter == MediaTypeFilter.GIF,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.GIF },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Document,
                            label = "Other",
                            selected = activeFilter == MediaTypeFilter.OTHER,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.OTHER },
                        )
                    }

                    Spacer(Modifier.weight(1f))

                    // Layout toggle + upload
                    GlassPill {
                        IconButton(
                            onClick = {
                                layoutMode = if (layoutMode == MediaLayoutMode.GRID)
                                    MediaLayoutMode.LIST else MediaLayoutMode.GRID
                            },
                            modifier = Modifier.size(40.dp),
                        ) {
                            Icon(
                                imageVector = if (layoutMode == MediaLayoutMode.GRID)
                                    NostrVaultIcons.CompactView else NostrVaultIcons.GridLayout,
                                contentDescription = if (layoutMode == MediaLayoutMode.GRID)
                                    "List view" else "Grid view",
                                tint = SecondaryText,
                                modifier = Modifier.size(25.dp),
                            )
                        }
                        IconButton(
                            onClick = {
                                mediaPickerLauncher.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
                                )
                            },
                            enabled = !isUploading,
                            modifier = Modifier.size(40.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Create,
                                contentDescription = "Upload",
                                tint = colors.primary,
                                modifier = Modifier.size(25.dp),
                            )
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            val scrollingDown by feedService.feedScrollingDown.collectAsState()
            // The FAB hides and shows with the scroll, so it is chrome.
            val fabSpring = Motion.chrome<Float>()
            AnimatedVisibility(
                visible = !scrollingDown,
                enter = scaleIn(animationSpec = fabSpring, initialScale = 0.5f) + fadeIn(fabSpring),
                exit = scaleOut(animationSpec = fabSpring, targetScale = 0.5f) + fadeOut(fabSpring),
            ) {
                Surface(
                    onClick = onBlossomClick,
                    modifier = Modifier.padding(bottom = 88.dp),
                    color = colors.primary,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Blossom,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Blossom",
                            color = PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isLoading,
            onRefresh = { viewModel.refresh() },
            modifier = Modifier.fillMaxSize(),
        ) {
            if (filteredItems.isEmpty() && !isLoading) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = padding.calculateTopPadding()),
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            imageVector = NostrVaultIcons.Media,
                            contentDescription = null,
                            tint = TertiaryText,
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(Modifier.height(12.dp))
                        Text("No media yet", color = SecondaryText, fontSize = 16.sp)
                    }
                }
            } else if (layoutMode == MediaLayoutMode.GRID) {
                // Grid view
                LazyVerticalGrid(
                    state = gridState,
                    columns = GridCells.Fixed(3),
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding() + 2.dp,
                        start = 2.dp,
                        end = 2.dp,
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    itemsIndexed(
                        items = filteredItems,
                        key = { _, item -> item.sha256 },
                    ) { index, item ->
                        MediaGridCell(
                            item = item,
                            index = index,
                            contextMenuTarget = contextMenuTarget,
                            noteId = noteIdByHash[item.sha256.lowercase()],
                            onNoteClick = onNoteClick,
                            onTap = {
                                MediaGalleryBridge.currentItems = filteredItems
                                onMediaClick(index)
                            },
                            onLongPress = { contextMenuTarget = index },
                            onDismissMenu = { contextMenuTarget = null },
                            mediaCacheService = mediaCacheService,
                            clipboardManager = clipboardManager,
                        )
                    }
                }
            } else {
                // List view
                LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding() + 4.dp,
                        start = 8.dp,
                        end = 8.dp,
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    itemsIndexed(
                        items = filteredItems,
                        key = { _, item -> item.sha256 },
                    ) { index, item ->
                        MediaListRow(
                            item = item,
                            index = index,
                            contextMenuTarget = contextMenuTarget,
                            noteId = noteIdByHash[item.sha256.lowercase()],
                            onNoteClick = onNoteClick,
                            onTap = {
                                MediaGalleryBridge.currentItems = filteredItems
                                onMediaClick(index)
                            },
                            onLongPress = { contextMenuTarget = index },
                            onDismissMenu = { contextMenuTarget = null },
                            mediaCacheService = mediaCacheService,
                            clipboardManager = clipboardManager,
                        )
                    }
                }
            }
        }
    }
}

/** Grid cell with context menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MediaGridCell(
    item: BlossomMediaItem,
    index: Int,
    contextMenuTarget: Int?,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
) {
    val context = LocalContext.current

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(2.dp))
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            ),
    ) {
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data(item.localFile ?: item.displayUrl)
                .size(360, 360)
                .crossfade(false) // Instant rendering for grid thumbnails
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )

        if (item.isVideo) {
            Icon(
                imageVector = NostrVaultIcons.PlayCircle,
                contentDescription = "Video",
                tint = Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(32.dp),
            )
        }

        // Source indicator dot (green = local blossom)
        if (item.isLocal) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(4.dp)
                    .size(8.dp)
                    .clip(CircleShape)
                    .then(Modifier.background(Color(0xFF4CAF50))),
            )
        }

        // Context menu
        MediaItemContextMenu(
            expanded = contextMenuTarget == index,
            item = item,
            noteId = noteId,
            onNoteClick = onNoteClick,
            onDismiss = onDismissMenu,
            mediaCacheService = mediaCacheService,
            clipboardManager = clipboardManager,
        )
    }
}

/** List row with thumbnail and metadata. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MediaListRow(
    item: BlossomMediaItem,
    index: Int,
    contextMenuTarget: Int?,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            )
            .padding(4.dp),
    ) {
        // Thumbnail
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(60.dp)
                .clip(RoundedCornerShape(6.dp)),
        ) {
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(item.localFile ?: item.displayUrl)
                    .size(160, 160)
                    .crossfade(false) // Instant rendering for list thumbnails
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            if (item.isVideo) {
                Icon(
                    imageVector = NostrVaultIcons.PlayCircle,
                    contentDescription = "Video",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(20.dp),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        // Metadata
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.sha256.take(12) + "...",
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Type badge
                Text(
                    text = when {
                        item.isVideo -> "Video"
                        item.isImage -> "Image"
                        else -> "Other"
                    },
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
                if (item.size != null && item.size > 0) {
                    Text(
                        text = " \u00B7 ${formatFileSize(item.size)}",
                        color = TertiaryText,
                        fontSize = 12.sp,
                    )
                }
                if (item.isLocal) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        imageVector = NostrVaultIcons.Blossom,
                        contentDescription = "Local",
                        tint = Color(0xFF4CAF50),
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }

        // Quick copy action
        IconButton(
            onClick = { clipboardManager.setText(AnnotatedString(item.displayUrl)) },
            modifier = Modifier.size(36.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Copy,
                contentDescription = "Copy link",
                tint = SecondaryText,
                modifier = Modifier.size(18.dp),
            )
        }

        // Context menu
        MediaItemContextMenu(
            expanded = contextMenuTarget == index,
            item = item,
            noteId = noteId,
            onNoteClick = onNoteClick,
            onDismiss = onDismissMenu,
            mediaCacheService = mediaCacheService,
            clipboardManager = clipboardManager,
        )
    }
}

/** Shared context menu for grid and list items. */
@Composable
private fun MediaItemContextMenu(
    expanded: Boolean,
    item: BlossomMediaItem,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onDismiss: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
) {
    val is404 = remember(item.displayUrl) { mediaCacheService.isKnown404(item.displayUrl) }

    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
    ) {
        // Only offered when a loaded note actually references this blob. An
        // always-present item that does nothing for most files would be the same
        // dead affordance in a different shape.
        if (noteId != null) {
            DropdownMenuItem(
                text = { Text("Open Note") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Articles, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onNoteClick(noteId)
                },
            )
        }
        DropdownMenuItem(
            text = { Text("Copy Link") },
            leadingIcon = {
                Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            onClick = {
                clipboardManager.setText(AnnotatedString(item.displayUrl))
                onDismiss()
            },
        )
        DropdownMenuItem(
            text = { Text(if (is404) "Remove from 404" else "Mark as 404") },
            leadingIcon = {
                Icon(NostrVaultIcons.Alert, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            onClick = {
                if (is404) {
                    mediaCacheService.unmarkNotFound(item.displayUrl)
                } else {
                    mediaCacheService.markNotFound(item.displayUrl)
                }
                onDismiss()
            },
        )
        if (!item.isLocal) {
            DropdownMenuItem(
                text = { Text("Mirror to Blossom") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Blossom, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    // Blossom mirror integration point
                    onDismiss()
                },
            )
        }
    }
}

/** Small icon button used in the media type filter toolbar. */
@Composable
private fun MediaFilterIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    selected: Boolean,
    accentColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick, modifier = Modifier.size(40.dp)) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (selected) accentColor else SecondaryText,
            modifier = Modifier.size(25.dp),
        )
    }
}

private fun formatFileSize(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
    }
}
