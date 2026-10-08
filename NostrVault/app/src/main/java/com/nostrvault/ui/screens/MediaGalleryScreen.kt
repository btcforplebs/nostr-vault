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
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.SwapVert
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.*
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.notification.ErrorStyle
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
    blobNoteIndexStore: com.nostrvault.data.local.BlobNoteIndexStore,
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
        // Auto-Mirror Media: pull own media from the mirrors (iOS triggerAutoMirrorIfEnabled).
        if (configStore.config.value.autoMirrorMedia) blossomService.runMirror()
    }

    fun refresh() {
        blossomService.forgetMirrorPresence()
        loadBlossomMedia()
    }

    /** hash → author of the note that posted the blob, where one has been seen. */
    val blobAuthors = blobNoteIndexStore.authors

    /** The pubkey a tile's Report Media / Block User acts on, or null to hide them. */
    fun moderationTarget(sha256: String, authors: Map<String, String>): String? =
        mediaModerationTarget(authors[sha256.lowercase()], nostrService.ownerHexPubkey, nostrService.activeHexPubkey)

    /**
     * NIP-56 report of a blob's author. A blob has no event to name, so it is
     * a user report, as iOS's UGCReportingDialog sends with no event id. The
     * caller also blocks, as reporting does everywhere else in the app.
     */
    fun reportAuthor(pubkey: String, reason: String, description: String) {
        nostrService.reportUser(pubkey, reason, description.ifBlank { null })
    }

    /** Each Blossom server's answer per blob; the tile badges read this. */
    val mirrorPresence = blossomService.mirrorPresence

    /** The user's outside Blossom servers, so badges re-check when one is added. */
    val blossomMirrors = configStore.config
        .map { it.activeBlossomMirrors }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.activeBlossomMirrors)

    fun backupSummary(sha256: String, presence: Map<String, Map<String, BlobPresence>>): BlossomBackupSummary? =
        blossomService.backupSummary(sha256, presence)

    /** Asks the servers about [sha256] once per session (or after a refresh). */
    suspend fun checkBackup(sha256: String) {
        blossomService.checkMirrorPresence(sha256)
    }

    private val _busySha = MutableStateFlow<String?>(null)
    /** The blob being saved or mirrored from the menu right now, or null. */
    val busySha = _busySha.asStateFlow()

    /**
     * Uploads a file already on this phone to the servers not known to have
     * it, then re-checks so the badge shows the new count. Port of iOS
     * `MediaBackupActions.mirrorMissing`.
     */
    fun mirrorMissing(item: BlossomMediaItem) {
        if (_busySha.value != null) return
        viewModelScope.launch {
            _busySha.value = item.sha256
            try {
                val result = pushMissing(item.sha256)
                when (result) {
                    null -> notificationManager.showToast("Already on all your Blossom servers")
                    is BlossomService.MirrorPushResult.AllAccepted -> notificationManager.showToast(result.message)
                    is BlossomService.MirrorPushResult.Partial -> notificationManager.showError(result.message, ErrorStyle.WARNING)
                    else -> notificationManager.showError(result.message)
                }
            } finally {
                _busySha.value = null
            }
        }
    }

    /**
     * Stores a file that is only on outside servers in the vault on this
     * phone, then uploads it to any server that lacks it. Port of iOS
     * `MediaBackupActions.saveToVault`.
     */
    fun saveToVault(item: BlossomMediaItem) {
        if (_busySha.value != null) return
        viewModelScope.launch {
            _busySha.value = item.sha256
            try {
                val saved = blossomService.mirrorUrlToLocal(item.displayUrl)
                if (saved == null) {
                    notificationManager.showError("Could not save to your vault")
                    return@launch
                }
                val backedUp = blossomMirrors.value.isNotEmpty() &&
                    pushMissing(saved).let { it == null || it is BlossomService.MirrorPushResult.AllAccepted }
                notificationManager.showToast(
                    if (backedUp) "Saved to your vault and your Blossom" else "Saved to your vault on this phone",
                )
                loadBlossomMedia()
            } finally {
                _busySha.value = null
            }
        }
    }

    /** Null when every server already had it; otherwise the push result. Re-checks after. */
    private suspend fun pushMissing(sha256: String): BlossomService.MirrorPushResult? {
        blossomService.checkMirrorPresence(sha256, force = true)
        val summary = blossomService.backupSummary(sha256)
        if (summary != null && !summary.needsMirror) return null
        val result = blossomService.pushLocalToMirrors(sha256, only = summary?.missing)
        blossomService.checkMirrorPresence(sha256, force = true)
        return result
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
                        .sortedByDescending { it.sortTime }
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

    /**
     * Uploads every picked file in turn (iOS photo picker and file importer
     * both allow several), then reloads once.
     */
    fun uploadMedia(uris: List<Uri>, contentResolver: android.content.ContentResolver) {
        if (_isUploading.value || uris.isEmpty()) return
        viewModelScope.launch {
            _isUploading.value = true
            try {
                var anySaved = false
                for (uri in uris) {
                    if (uploadOne(uri, contentResolver)) anySaved = true
                }
                if (anySaved) refresh()
            } finally {
                _isUploading.value = false
            }
        }
    }

    /**
     * Port of iOS `handlePasteFromClipboard`: an image on the clipboard is
     * uploaded like a picked file; an http(s) link is downloaded into the
     * vault; anything else says why nothing happened.
     */
    fun pasteFromClipboard(context: android.content.Context) {
        val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
            as? android.content.ClipboardManager
        val item = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val uri = item?.uri
        if (uri != null) {
            uploadMedia(listOf(uri), context.contentResolver)
            return
        }
        val text = item?.text?.toString()?.trim()
        if (text.isNullOrEmpty()) {
            notificationManager.showError("Clipboard is empty or contains unsupported content", ErrorStyle.WARNING)
            return
        }
        val url = pastedMediaUrl(text)
        if (url == null) {
            notificationManager.showError("Clipboard does not contain a valid URL or image", ErrorStyle.WARNING)
            return
        }
        if (_isUploading.value) return
        viewModelScope.launch {
            _isUploading.value = true
            val filename = url.substringBefore('?').substringBefore('#')
                .substringAfterLast('/').ifEmpty { "pasted-media" }
            val uploadId = notificationManager.addUpload(filename)
            try {
                if (blossomService.mirrorUrlToLocal(url) != null) {
                    notificationManager.markUploadSuccess(uploadId)
                    refresh()
                } else {
                    notificationManager.markUploadFailed(uploadId, "Failed to paste media")
                }
            } finally {
                _isUploading.value = false
            }
        }
    }

    /** True when the file reached the vault. Progress and failure go to the upload notification. */
    private suspend fun uploadOne(uri: Uri, contentResolver: android.content.ContentResolver): Boolean {
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
                return false
            }

            val contentType = contentResolver.getType(uri) ?: "application/octet-stream"
            if (!withContext(Dispatchers.IO) { MediaPrivacy.removeLocation(tempFile!!, contentType) }) {
                notificationManager.markUploadFailed(uploadId, MediaPrivacy.FAILURE_MESSAGE)
                return false
            }
            val sha256 = withContext(Dispatchers.IO) {
                blossomService.computeSHA256(tempFile!!)
            }

            notificationManager.updateUploadProgress(uploadId, 0.3f)

            val resultUrl = withContext(Dispatchers.IO) {
                // Vault save: local storage counts as success even if mirrors are down.
                blossomService.uploadAndMirror(tempFile!!, sha256, contentType, allowLocalFallback = true)
            }

            notificationManager.updateUploadProgress(uploadId, 1.0f)

            return if (resultUrl != null || blossomService.localBlossomURL() != null) {
                notificationManager.markUploadSuccess(uploadId)
                true
            } else {
                notificationManager.markUploadFailed(uploadId, "Upload failed")
                false
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Upload failed", e)
            notificationManager.markUploadFailed(uploadId, e.message ?: "Upload failed")
            return false
        } finally {
            tempFile?.let { withContext(NonCancellable + Dispatchers.IO) { it.delete() } }
        }
    }

    companion object {
        private const val TAG = "MediaGalleryVM"
    }
}

/**
 * The http(s) link a pasted string names, or null. Port of the URL check in
 * iOS `handlePasteFromClipboard`: anything without an http(s) scheme and a
 * host is not something to download.
 */
internal fun pastedMediaUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) return null
    val uri = runCatching { java.net.URI(trimmed) }.getOrNull() ?: return null
    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") return null
    if (uri.host.isNullOrEmpty()) return null
    return trimmed
}

internal const val MEDIA_GALLERY_PREFS = "media_gallery"

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

    /** Seconds since epoch the gallery orders by, newest first: upload time, else file mtime. */
    val sortTime: Long get() = uploaded ?: lastModified?.div(1000) ?: 0L

    /** GIF detection by extension or mime type, matching iOS MediaGallery isGif. */
    val isGif: Boolean get() =
        mimeType?.contains("gif", ignoreCase = true) == true ||
            displayUrl.substringBefore('?').substringBefore('#')
                .substringAfterLast('.', "").equals("gif", ignoreCase = true)
}

data class MediaItem(val url: String, val noteId: String)

/**
 * Who Report Media / Block User on a tile act on: the author of the note the
 * blob was posted in, when that is someone else. Null — the items hidden —
 * when no note is known, or it is yours (owner or the account in use).
 * iOS MediaGridItem: `item.pubkey != nostrService.activeHexPubkey`.
 */
internal fun mediaModerationTarget(author: String?, ownerHex: String, activeHex: String): String? =
    author?.takeIf { it.isNotEmpty() && it != ownerHex && it != activeHex }

/** Scope for a pending destructive delete in MediaViewerScreen. */
enum class DeleteScope { MIRRORS, EVERYWHERE }

/** Media type filter matching iOS MediaTypeFilter. */
enum class MediaTypeFilter {
    ALL, PHOTO, VIDEO, GIF, OTHER;

    /**
     * Whether [item] belongs under this filter. Shared by the Media tab and
     * the composer's relay picker so the two can't drift.
     */
    fun matches(item: BlossomMediaItem): Boolean = when (this) {
        ALL -> true
        PHOTO -> item.isImage && !item.isGif
        VIDEO -> item.isVideo
        GIF -> item.isGif
        OTHER -> !item.isImage && !item.isVideo
    }
}

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
    /** The viewer's save and delete actions, reused by the long-press menu. */
    mediaActions: MediaViewerViewModel = hiltViewModel(),
) {
    val mediaItems by viewModel.mediaItems.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    var activeFilter by remember { mutableStateOf(MediaTypeFilter.ALL) }
    var layoutMode by remember { mutableStateOf(MediaLayoutMode.GRID) }
    val gridState = rememberLazyGridState()
    val listState = rememberLazyListState()

    // Where the list is relative to its top: the chrome always shows near it. Tracks
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
    )
    // Tapping the Media tab again goes to the top of the grid or list (iOS #275).
    LaunchedEffect(isGrid) {
        com.nostrvault.ui.navigation.TabReselect.of(com.nostrvault.ui.navigation.Screen.MediaGallery).collect {
            if (isGrid) gridState.animateScrollToItem(0) else listState.animateScrollToItem(0)
        }
    }
    var contextMenuTarget by remember { mutableStateOf<Int?>(null) }
    var pendingDelete by remember { mutableStateOf<Pair<BlossomMediaItem, DeleteScope>?>(null) }
    // Report Media / Block User from the long-press menu: the author's pubkey.
    var reportTarget by remember { mutableStateOf<String?>(null) }
    var blockTarget by remember { mutableStateOf<String?>(null) }
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val mediaCacheService = viewModel.mediaCacheService

    // nostrvault://mediapaste: paste once the tab is on screen. A beat behind,
    // as iOS does; Android also hides the clipboard until the window has focus.
    val pasteRequested by com.nostrvault.ui.navigation.PendingMediaPaste.requested.collectAsState()
    LaunchedEffect(pasteRequested) {
        if (!pasteRequested) return@LaunchedEffect
        kotlinx.coroutines.delay(400)
        if (com.nostrvault.ui.navigation.PendingMediaPaste.consume()) viewModel.pasteFromClipboard(context)
    }

    // Upload choices, as on iOS: Photos and Videos pick several at once from
    // the photo picker, Files opens the document picker (images and videos,
    // several at once), Paste takes an image or link from the clipboard.
    var showUploadMenu by remember { mutableStateOf(false) }
    val mediaPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(),
    ) { uris: List<Uri> ->
        viewModel.uploadMedia(uris, context.contentResolver)
    }
    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris: List<Uri> ->
        viewModel.uploadMedia(uris, context.contentResolver)
    }

    // A blob carries no note reference; the sha256 is the only join.
    //
    // Read from the persistent index rather than recomputed from the loaded
    // feed. Computed from the feed, the same file offered "Open Note" or did
    // not depending on how far the user had scrolled earlier in the session —
    // a state they cannot see and cannot predict. The index keeps every mapping
    // the feed has ever handed it, so the answer is a property of the blob.
    val noteIdByHash by feedService.blobNoteIndex.collectAsState()
    val authorByHash by viewModel.blobAuthors.collectAsState()
    val mirrorPresence by viewModel.mirrorPresence.collectAsState()
    val blossomMirrors by viewModel.blossomMirrors.collectAsState()
    val busySha by viewModel.busySha.collectAsState()

    // Sort choice survives relaunches, like iOS's @AppStorage(MediaSortOption.storageKey).
    val sortPrefs = remember { context.getSharedPreferences(MEDIA_GALLERY_PREFS, android.content.Context.MODE_PRIVATE) }
    var sortOption by remember {
        mutableStateOf(MediaSortOption.fromKey(sortPrefs.getString(MediaSortOption.STORAGE_KEY, null)))
    }
    var showSortMenu by remember { mutableStateOf(false) }

    val filteredItems = remember(mediaItems, activeFilter, sortOption) {
        sortOption.sorted(mediaItems.filter { activeFilter.matches(it) })
    }
    // Today / This Week / This Month / month headings, only under a date sort.
    val sections = remember(filteredItems, sortOption) {
        MediaDateGrouping.sections(filteredItems, sortOption)
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
                    // Leading: media type filter icons. No "Other" chip, as on
                    // iOS: the row now also holds the sort menu, and All still
                    // includes those files.
                    MediaTypeFilterPill(
                        active = activeFilter,
                        onSelect = { activeFilter = it },
                        filters = MediaTypeFilter.entries - MediaTypeFilter.OTHER,
                    )

                    Spacer(Modifier.weight(1f))

                    // Sort + layout toggle + upload
                    GlassPill {
                        Box {
                            IconButton(
                                onClick = { showSortMenu = true },
                                modifier = Modifier.size(40.dp),
                            ) {
                                Icon(
                                    imageVector = androidx.compose.material.icons.Icons.Filled.SwapVert,
                                    contentDescription = "Sort by: ${sortOption.label}",
                                    tint = SecondaryText,
                                    modifier = Modifier.size(25.dp),
                                )
                            }
                            DropdownMenu(
                                expanded = showSortMenu,
                                onDismissRequest = { showSortMenu = false },
                            ) {
                                for (option in MediaSortOption.entries) {
                                    DropdownMenuItem(
                                        text = { Text(option.label) },
                                        // A checkmark on the active row: one choice of many.
                                        leadingIcon = {
                                            if (option == sortOption) {
                                                Icon(
                                                    androidx.compose.material.icons.Icons.Filled.Check,
                                                    contentDescription = "Selected",
                                                    tint = colors.primary,
                                                    modifier = Modifier.size(20.dp),
                                                )
                                            } else {
                                                Spacer(Modifier.size(20.dp))
                                            }
                                        },
                                        onClick = {
                                            showSortMenu = false
                                            sortOption = option
                                            sortPrefs.edit().putString(MediaSortOption.STORAGE_KEY, option.key).apply()
                                        },
                                    )
                                }
                            }
                        }
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
                        Box {
                            IconButton(
                                onClick = { showUploadMenu = true },
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
                            DropdownMenu(
                                expanded = showUploadMenu,
                                onDismissRequest = { showUploadMenu = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Photos") },
                                    leadingIcon = { Icon(NostrVaultIcons.Media, contentDescription = null, modifier = Modifier.size(20.dp)) },
                                    onClick = {
                                        showUploadMenu = false
                                        mediaPickerLauncher.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                        )
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Videos") },
                                    leadingIcon = { Icon(NostrVaultIcons.Video, contentDescription = null, modifier = Modifier.size(20.dp)) },
                                    onClick = {
                                        showUploadMenu = false
                                        mediaPickerLauncher.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly),
                                        )
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Files") },
                                    leadingIcon = { Icon(NostrVaultIcons.Document, contentDescription = null, modifier = Modifier.size(20.dp)) },
                                    onClick = {
                                        showUploadMenu = false
                                        filePickerLauncher.launch(arrayOf("image/*", "video/*"))
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Magic Paste") },
                                    leadingIcon = {
                                        Icon(
                                            androidx.compose.material.icons.Icons.Filled.ContentPaste,
                                            contentDescription = null,
                                            modifier = Modifier.size(20.dp),
                                        )
                                    },
                                    onClick = {
                                        showUploadMenu = false
                                        viewModel.pasteFromClipboard(context)
                                    },
                                )
                            }
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            // The FAB folds with the bars, following the finger.
            val folded by rememberChromeFolded()
            Box(Modifier.chromeFab().blockedWhen(folded)) {
                Surface(
                    onClick = onBlossomClick,
                    modifier = Modifier.floatingRowButton(),
                    color = colors.primary,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .height(FloatingButtonRow.buttonHeight)
                            .padding(horizontal = 18.dp),
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
                    for (section in sections) {
                        if (section.title.isNotEmpty()) {
                            item(
                                key = "header:${section.title}",
                                span = { GridItemSpan(maxLineSpan) },
                                contentType = "header",
                            ) {
                                MediaSectionHeader(section.title)
                            }
                        }
                        itemsIndexed(
                            items = section.items,
                            key = { _, item -> item.sha256 },
                            contentType = { _, _ -> "media" },
                        ) { offset, item ->
                            val index = section.startIndex + offset
                            MediaGridCell(
                                item = item,
                                index = index,
                                backup = BackupBadgeState(
                                    summary = viewModel.backupSummary(item.sha256, mirrorPresence),
                                    mirrorCount = blossomMirrors.size,
                                    mirrorsKey = blossomMirrors,
                                    busy = busySha == item.sha256,
                                    check = { viewModel.checkBackup(item.sha256) },
                                    onMirror = { viewModel.mirrorMissing(item) },
                                    onSaveToVault = { viewModel.saveToVault(item) },
                                ),
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
                                shareLink = publicBlossomLink(item, blossomMirrors),
                                onSaveToPhotos = { mediaActions.saveToGallery(item) },
                                onDelete = { scope -> pendingDelete = item to scope },
                                moderationTarget = viewModel.moderationTarget(item.sha256, authorByHash),
                                onReport = { reportTarget = it },
                                onBlock = { blockTarget = it },
                            )
                        }
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
                    for (section in sections) {
                        if (section.title.isNotEmpty()) {
                            stickyHeader(key = "header:${section.title}", contentType = "header") {
                                MediaSectionHeader(section.title)
                            }
                        }
                        itemsIndexed(
                            items = section.items,
                            key = { _, item -> item.sha256 },
                            contentType = { _, _ -> "media" },
                        ) { offset, item ->
                            val index = section.startIndex + offset
                            MediaListRow(
                                item = item,
                                index = index,
                                backup = BackupBadgeState(
                                    summary = viewModel.backupSummary(item.sha256, mirrorPresence),
                                    mirrorCount = blossomMirrors.size,
                                    mirrorsKey = blossomMirrors,
                                    busy = busySha == item.sha256,
                                    check = { viewModel.checkBackup(item.sha256) },
                                    onMirror = { viewModel.mirrorMissing(item) },
                                    onSaveToVault = { viewModel.saveToVault(item) },
                                ),
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
                                shareLink = publicBlossomLink(item, blossomMirrors),
                                onSaveToPhotos = { mediaActions.saveToGallery(item) },
                                onDelete = { scope -> pendingDelete = item to scope },
                                moderationTarget = viewModel.moderationTarget(item.sha256, authorByHash),
                                onReport = { reportTarget = it },
                                onBlock = { blockTarget = it },
                            )
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { (item, scope) ->
        DeleteBlobConfirmDialog(
            scope = scope,
            onConfirm = {
                pendingDelete = null
                when (scope) {
                    DeleteScope.MIRRORS -> mediaActions.deleteFromMirrors(item) { viewModel.refresh() }
                    DeleteScope.EVERYWHERE -> mediaActions.deleteEverywhere(item) { viewModel.refresh() }
                }
            },
            onDismiss = { pendingDelete = null },
        )
    }

    // Reporting also blocks the author, as on iOS and everywhere else in the app.
    reportTarget?.let { pubkey ->
        com.nostrvault.ui.components.UGCReportDialog(
            onReport = { reason, description ->
                reportTarget = null
                viewModel.reportAuthor(pubkey, reason, description)
                feedService.blockUser(pubkey)
            },
            onDismiss = { reportTarget = null },
        )
    }
    blockTarget?.let { pubkey ->
        AlertDialog(
            onDismissRequest = { blockTarget = null },
            title = { Text("Block User") },
            text = { Text("Block this user? Their posts will be hidden from your feed.") },
            confirmButton = {
                TextButton(onClick = {
                    blockTarget = null
                    feedService.blockUser(pubkey)
                }) { Text("Block", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { blockTarget = null }) { Text("Cancel") }
            },
        )
    }
}

/** Heading over one dated run of media (iOS `mediaSectionHeader`). */
@Composable
internal fun MediaSectionHeader(title: String) {
    Text(
        text = title,
        color = PrimaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.3.sp,
        modifier = Modifier
            .fillMaxWidth()
            .background(WindowBackground.copy(alpha = 0.92f))
            .padding(horizontal = 6.dp, vertical = 8.dp),
    )
}

/** Grid cell with context menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MediaGridCell(
    item: BlossomMediaItem,
    index: Int,
    backup: BackupBadgeState,
    contextMenuTarget: Int?,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
    shareLink: String,
    onSaveToPhotos: () -> Unit,
    onDelete: (DeleteScope) -> Unit,
    moderationTarget: String?,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
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

        // How many of your Blossom servers hold it, so you can spot what is
        // not backed up without opening it.
        if (backup.mirrorCount > 0) {
            BlossomBackupBadge(
                backup = backup,
                compact = true,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(4.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 5.dp, vertical = 2.dp),
            )
        }

        // Context menu
        MediaItemContextMenu(
            expanded = contextMenuTarget == index,
            item = item,
            backup = backup,
            noteId = noteId,
            onNoteClick = onNoteClick,
            onDismiss = onDismissMenu,
            mediaCacheService = mediaCacheService,
            clipboardManager = clipboardManager,
            shareLink = shareLink,
            onSaveToPhotos = onSaveToPhotos,
            onDelete = onDelete,
            moderationTarget = moderationTarget,
            onReport = onReport,
            onBlock = onBlock,
        )
    }
}

/** List row with thumbnail and metadata. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MediaListRow(
    item: BlossomMediaItem,
    index: Int,
    backup: BackupBadgeState,
    contextMenuTarget: Int?,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
    shareLink: String,
    onSaveToPhotos: () -> Unit,
    onDelete: (DeleteScope) -> Unit,
    moderationTarget: String?,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
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
                if (backup.mirrorCount > 0) {
                    Spacer(Modifier.width(8.dp))
                    BlossomBackupBadge(backup = backup)
                }
            }
        }

        // Quick copy action
        IconButton(
            onClick = { clipboardManager.setText(AnnotatedString(shareLink)) },
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
            backup = backup,
            noteId = noteId,
            onNoteClick = onNoteClick,
            onDismiss = onDismissMenu,
            mediaCacheService = mediaCacheService,
            clipboardManager = clipboardManager,
            shareLink = shareLink,
            onSaveToPhotos = onSaveToPhotos,
            onDelete = onDelete,
            moderationTarget = moderationTarget,
            onReport = onReport,
            onBlock = onBlock,
        )
    }
}

/** Shared context menu for grid and list items. */
@Composable
private fun MediaItemContextMenu(
    expanded: Boolean,
    item: BlossomMediaItem,
    backup: BackupBadgeState,
    noteId: String?,
    onNoteClick: (String) -> Unit,
    onDismiss: () -> Unit,
    mediaCacheService: MediaCacheService,
    clipboardManager: androidx.compose.ui.platform.ClipboardManager,
    shareLink: String,
    onSaveToPhotos: () -> Unit,
    onDelete: (DeleteScope) -> Unit,
    /** Someone else's media: offer Report Media and Block User on them. */
    moderationTarget: String?,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
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
                clipboardManager.setText(AnnotatedString(shareLink))
                onDismiss()
            },
        )
        if (item.isImage || item.isVideo) {
            DropdownMenuItem(
                text = { Text("Save to Photos") },
                leadingIcon = {
                    Icon(NostrVaultIcons.Import, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onSaveToPhotos()
                },
            )
        }
        if (!item.isLocal) {
            DropdownMenuItem(
                text = { Text(if (backup.busy) "Saving…" else "Save to Vault") },
                enabled = !backup.busy,
                leadingIcon = {
                    Icon(NostrVaultIcons.Storage, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    backup.onSaveToVault()
                },
            )
        } else if (backup.summary?.needsMirror == true) {
            // On the phone, and some Blossom server does not have it yet.
            DropdownMenuItem(
                text = { Text(if (backup.busy) "Mirroring…" else "Mirror to Blossom") },
                enabled = !backup.busy,
                leadingIcon = {
                    Icon(NostrVaultIcons.ArrowUp, contentDescription = null, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    backup.onMirror()
                },
            )
        }
        // Order as iOS: saving and mirroring, then the deletes (each asks
        // for confirmation first, as in the viewer), then Mark as 404.
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text("Delete from mirrors", color = ErrorRed) },
            leadingIcon = {
                Icon(NostrVaultIcons.Cloud, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp))
            },
            onClick = {
                onDismiss()
                onDelete(DeleteScope.MIRRORS)
            },
        )
        DropdownMenuItem(
            text = { Text("Delete everywhere", color = ErrorRed) },
            leadingIcon = {
                Icon(NostrVaultIcons.Delete, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp))
            },
            onClick = {
                onDismiss()
                onDelete(DeleteScope.EVERYWHERE)
            },
        )
        HorizontalDivider()
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
        // Last, as on iOS: only for media someone else posted.
        if (moderationTarget != null) {
            DropdownMenuItem(
                text = { Text("Report Media", color = ErrorRed) },
                leadingIcon = {
                    Icon(NostrVaultIcons.Flag, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onReport(moderationTarget)
                },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Block User", color = ErrorRed) },
                leadingIcon = {
                    Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(20.dp))
                },
                onClick = {
                    onDismiss()
                    onBlock(moderationTarget)
                },
            )
        }
    }
}

/**
 * The Media tab's type filter buttons. Also used by the composer's relay
 * picker, which offers only the [filters] it can attach.
 */
@Composable
internal fun MediaTypeFilterPill(
    active: MediaTypeFilter,
    onSelect: (MediaTypeFilter) -> Unit,
    filters: List<MediaTypeFilter> = MediaTypeFilter.entries,
) {
    val colors = LocalNostrVaultColors.current
    GlassPill {
        for (filter in filters) {
            val (icon, label) = when (filter) {
                MediaTypeFilter.ALL -> NostrVaultIcons.GridLayout to "All"
                MediaTypeFilter.PHOTO -> NostrVaultIcons.Media to "Photos"
                MediaTypeFilter.VIDEO -> NostrVaultIcons.Video to "Videos"
                MediaTypeFilter.GIF -> NostrVaultIcons.Gif to "GIFs"
                MediaTypeFilter.OTHER -> NostrVaultIcons.Document to "Other"
            }
            MediaFilterIcon(
                icon = icon,
                label = label,
                selected = active == filter,
                accentColor = colors.primary,
                onClick = { onSelect(filter) },
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

/** One tile's Blossom backup answer and the actions on it. */
@Stable
internal class BackupBadgeState(
    /** Null until every configured server has answered once. */
    val summary: BlossomBackupSummary?,
    val mirrorCount: Int,
    /** The server list, so adding one asks again instead of leaving the count unknown. */
    val mirrorsKey: List<String>,
    val busy: Boolean,
    val check: suspend () -> Unit,
    val onMirror: () -> Unit,
    val onSaveToVault: () -> Unit,
)

/**
 * The cloud "x/y" badge: green on every server, orange on some, grey on none,
 * "?" when a server could not be asked. Port of iOS `BlossomBackupBadge`.
 */
@Composable
internal fun BlossomBackupBadge(
    backup: BackupBadgeState,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val summary = backup.summary
    // Re-runs after a pull to refresh clears the answers (summary goes null).
    LaunchedEffect(backup.mirrorsKey, summary == null) {
        if (summary == null) backup.check()
    }
    val tint = when {
        summary == null || summary.present == 0 -> SecondaryText
        summary.isComplete -> Color(0xFF4CAF50)
        else -> Color(0xFFFF9800)
    }
    val total = backup.mirrorCount
    val text = when {
        summary == null -> "–/$total"
        summary.unreachable > 0 && summary.present < summary.total -> "${summary.present}/$total?"
        else -> "${summary.present}/$total"
    }
    val label = when {
        summary == null -> "Checking your Blossom servers"
        summary.unreachable > 0 -> "On ${summary.present} of $total Blossom servers, ${summary.unreachable} could not be reached"
        else -> "On ${summary.present} of $total Blossom servers"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.semantics(mergeDescendants = true) { contentDescription = label },
    ) {
        Icon(
            imageVector = if (summary?.isComplete == true) NostrVaultIcons.CloudDone else NostrVaultIcons.Cloud,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(if (compact) 10.dp else 13.dp),
        )
        Spacer(Modifier.width(3.dp))
        Text(
            text = text,
            color = tint,
            fontSize = if (compact) 10.sp else 12.sp,
            fontWeight = FontWeight.SemiBold,
            style = androidx.compose.ui.text.TextStyle(fontFeatureSettings = "tnum"),
        )
    }
}
