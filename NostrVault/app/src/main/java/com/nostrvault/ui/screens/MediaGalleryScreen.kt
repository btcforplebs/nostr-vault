package com.nostrvault.ui.screens

import android.net.Uri
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.itemsIndexed
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
    private val mediaUploadManager: MediaUploadManager,
) : ViewModel() {

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    /** Upload state is owned by the app-scoped manager (uploads also come from the
     *  system share sheet), so the gallery just reflects it. */
    val isUploading = mediaUploadManager.isUploading

    private val _mediaItems = MutableStateFlow<List<BlossomMediaItem>>(emptyList())
    val mediaItems = _mediaItems.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    init {
        loadBlossomMedia()
        // Refresh the grid when any upload finishes (gallery picker or share sheet).
        viewModelScope.launch {
            mediaUploadManager.uploadCompleted.collect { refresh() }
        }
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

                    // 4. Extract media from the owner's own notes (iOS parity).
                    // Surfaces media referenced in notes that may not exist as a
                    // local Blossom blob. Deduped against blossom blobs by hash.
                    val ownerPk = nostrService.activeHexPubkey
                    if (ownerPk.isNotEmpty()) {
                        try {
                            val notes = nostrService.fetchOwnerMediaNotes(ownerPk)
                            for (note in notes) {
                                for (url in note.mediaURLs) {
                                    val key = noteMediaKey(url)
                                    if (items.containsKey(key)) continue // blossom blob wins
                                    items[key] = BlossomMediaItem(
                                        sha256 = blossomHashOf(url) ?: "",
                                        displayUrl = url,
                                        localFile = null,
                                        mimeType = mimeFromUrl(url),
                                        size = null,
                                        uploaded = note.createdAt.time / 1000,
                                        lastModified = null,
                                        isLocal = false,
                                    )
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Owner note media extraction failed: ${e.message}")
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
        // Delegate to the app-scoped manager: it owns temp-file streaming, SHA-256,
        // Blossom upload/mirror, notifications, and serialization. The gallery
        // refreshes via the uploadCompleted collector in init.
        mediaUploadManager.upload(uri, contentResolver)
    }

    private val _mirrorCounts = MutableStateFlow<Map<String, Int>>(emptyMap())
    val mirrorCounts: StateFlow<Map<String, Int>> = _mirrorCounts.asStateFlow()

    val totalMirrors: Int
        get() = configStore.config.value.activeBlossomMirrors.size

    fun loadMirrorCount(sha256: String) {
        if (_mirrorCounts.value.containsKey(sha256)) return
        viewModelScope.launch(Dispatchers.IO) {
            val status = blossomService.checkMirrorStatus(sha256)
            val count = status.values.count { it }
            _mirrorCounts.update { it + (sha256 to count) }
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
) {
    val isVideo: Boolean get() = mimeType?.startsWith("video") == true
    val isImage: Boolean get() = mimeType?.startsWith("image") == true || mimeType == "image"

    /** Unique, stable key for LazyGrid/LazyColumn. Note-derived items may lack a
     *  real SHA256, so fall back to the display URL. */
    val stableKey: String get() = sha256.ifEmpty { displayUrl }
}

data class MediaItem(val url: String, val noteId: String)

private val BLOSSOM_HASH_IN_URL = Regex("([a-f0-9]{64})", RegexOption.IGNORE_CASE)

/** Extract the trailing 64-hex Blossom hash from a URL, if present (lowercased). */
private fun blossomHashOf(url: String): String? {
    val lastSegment = url.substringBefore('?').substringBefore('#').substringAfterLast('/')
    return BLOSSOM_HASH_IN_URL.find(lastSegment)?.value?.lowercase()
}

/** Dedup key for a note media URL: Blossom hash if present (collapses onto the
 *  stored blob), otherwise the URL itself. Mirrors iOS normalizedKey. */
private fun noteMediaKey(url: String): String = blossomHashOf(url) ?: url

/** Best-effort MIME from a URL's file extension. Null is allowed downstream
 *  (the gallery filter admits null-MIME items and Coil still renders them). */
private fun mimeFromUrl(url: String): String? {
    val ext = url.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase()
    return when (ext) {
        "jpg", "jpeg", "png", "webp", "bmp", "heic", "avif" -> "image/$ext"
        "gif" -> "image/gif"
        "mp4", "webm", "mov", "m4v", "avi", "mkv" -> "video/$ext"
        else -> null
    }
}

/** Media type filter matching iOS MediaTypeFilter. */
enum class MediaTypeFilter { ALL, PHOTO, VIDEO, GIF, OTHER }

/** Media location/source filter matching iOS MediaLocationFilter. */
enum class MediaLocationFilter { ALL, BLOSSOM, CACHED }

/** Gallery layout mode. */
enum class MediaLayoutMode { GRID, LIST }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MediaGalleryScreen(
    onMediaClick: (Int) -> Unit,
    onNoteClick: (String) -> Unit,
    onBlossomClick: () -> Unit,
    viewModel: MediaGalleryViewModel = hiltViewModel(),
) {
    val mediaItems by viewModel.mediaItems.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    val mirrorCounts by viewModel.mirrorCounts.collectAsState()
    val totalMirrors = viewModel.totalMirrors
    var activeFilter by remember { mutableStateOf(MediaTypeFilter.ALL) }
    var locationFilter by remember { mutableStateOf(MediaLocationFilter.ALL) }
    var layoutMode by remember { mutableStateOf(MediaLayoutMode.GRID) }
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

    val filteredItems = remember(mediaItems, activeFilter, locationFilter) {
        mediaItems
            .filter { item ->
                when (activeFilter) {
                    MediaTypeFilter.ALL -> true
                    MediaTypeFilter.PHOTO -> item.isImage
                    MediaTypeFilter.VIDEO -> item.isVideo
                    MediaTypeFilter.GIF -> item.mimeType?.contains("gif", ignoreCase = true) == true
                    MediaTypeFilter.OTHER -> !item.isImage && !item.isVideo
                }
            }
            .filter { item ->
                when (locationFilter) {
                    MediaLocationFilter.ALL -> true
                    MediaLocationFilter.BLOSSOM -> item.isLocal
                    MediaLocationFilter.CACHED -> mediaCacheService.isCached(item.displayUrl)
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
                            icon = NostrVaultIcons.Document,
                            label = "Other",
                            selected = activeFilter == MediaTypeFilter.OTHER,
                            accentColor = colors.primary,
                            onClick = { activeFilter = MediaTypeFilter.OTHER },
                        )
                    }

                    Spacer(Modifier.weight(1f))

                    // Source filter + layout toggle + upload
                    GlassPill {
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Blossom,
                            label = "Blossom",
                            selected = locationFilter == MediaLocationFilter.BLOSSOM,
                            accentColor = colors.primary,
                            onClick = {
                                locationFilter = if (locationFilter == MediaLocationFilter.BLOSSOM)
                                    MediaLocationFilter.ALL else MediaLocationFilter.BLOSSOM
                            },
                        )
                        MediaFilterIcon(
                            icon = NostrVaultIcons.Storage,
                            label = "Cached",
                            selected = locationFilter == MediaLocationFilter.CACHED,
                            accentColor = colors.primary,
                            onClick = {
                                locationFilter = if (locationFilter == MediaLocationFilter.CACHED)
                                    MediaLocationFilter.ALL else MediaLocationFilter.CACHED
                            },
                        )
                    }

                    Spacer(Modifier.width(6.dp))

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
                        key = { _, item -> item.stableKey },
                    ) { index, item ->
                        MediaGridCell(
                            item = item,
                            index = index,
                            contextMenuTarget = contextMenuTarget,
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
                        key = { _, item -> item.stableKey },
                    ) { index, item ->
                        if (item.isLocal) {
                            LaunchedEffect(item.sha256) { viewModel.loadMirrorCount(item.sha256) }
                        }
                        MediaListRow(
                            item = item,
                            index = index,
                            contextMenuTarget = contextMenuTarget,
                            onTap = {
                                MediaGalleryBridge.currentItems = filteredItems
                                onMediaClick(index)
                            },
                            onLongPress = { contextMenuTarget = index },
                            onDismissMenu = { contextMenuTarget = null },
                            mediaCacheService = mediaCacheService,
                            clipboardManager = clipboardManager,
                            mirrorCount = if (item.isLocal) mirrorCounts[item.sha256] else null,
                            totalMirrors = totalMirrors,
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
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
    mirrorCount: Int? = null,
    totalMirrors: Int = 0,
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
            // Mirror count badge (local items only, when mirrors are configured)
            if (item.isLocal && totalMirrors > 0) {
                Spacer(Modifier.height(3.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val badgeColor = when {
                        mirrorCount == null -> TertiaryText
                        mirrorCount == totalMirrors -> Color(0xFF4CAF50)
                        mirrorCount > 0 -> Color(0xFFFF9800)
                        else -> TertiaryText
                    }
                    Icon(
                        imageVector = NostrVaultIcons.Cloud,
                        contentDescription = null,
                        tint = badgeColor,
                        modifier = Modifier.size(12.dp),
                    )
                    Spacer(Modifier.width(3.dp))
                    Text(
                        text = if (mirrorCount == null) "…" else "$mirrorCount / $totalMirrors",
                        color = badgeColor,
                        fontSize = 11.sp,
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
    onDismiss: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
) {
    val is404 = remember(item.displayUrl) { mediaCacheService.isKnown404(item.displayUrl) }

    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
    ) {
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
