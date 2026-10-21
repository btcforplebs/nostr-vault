package com.nostrvault.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
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
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.service.*
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.LocalVaultMessages
import com.nostrvault.ui.components.VaultMessagesButton
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** iOS `mediaGallery.layoutMode`. */
private const val LAYOUT_MODE_KEY = "mediaGallery.layoutMode"

@Composable
private fun MediaEmptyStateView(state: MediaEmptyState) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        if (state == MediaEmptyState.LOADING) {
            CircularProgressIndicator(modifier = Modifier.size(40.dp))
        } else {
            Icon(
                imageVector = NostrVaultIcons.Media,
                contentDescription = null,
                tint = TertiaryText,
                modifier = Modifier.size(48.dp),
            )
        }
        Spacer(Modifier.height(16.dp))
        Text(state.title, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        state.detail?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = SecondaryText, fontSize = 13.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MediaGalleryScreen(
    onMediaClick: (Int) -> Unit,
    onNoteClick: (String) -> Unit,
    /** The Vault Dashboard (relay and Blossom in one), which the Vault tab presents. */
    onOpenDashboard: () -> Unit,
    /** The Vault tab's mode pill, on Media. */
    modePill: @Composable () -> Unit,
    /** The relay's health, which colours the Vault button as on the relay half. */
    dashboardColor: androidx.compose.ui.graphics.Color,
    feedService: FeedService,
    viewModel: MediaGalleryViewModel = hiltViewModel(),
    /** The viewer's save and delete actions, reused by the long-press menu. */
    mediaActions: MediaViewerViewModel = hiltViewModel(),
) {
    val mediaItems by viewModel.mediaItems.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    val context = LocalContext.current
    // Type filter and layout survive relaunches, like iOS's @AppStorage.
    val galleryPrefs = remember { context.getSharedPreferences(MEDIA_GALLERY_PREFS, android.content.Context.MODE_PRIVATE) }
    val (typeSelection, onTypeTap) = rememberMediaTypeSelection()
    var layoutMode by remember {
        mutableStateOf(
            MediaLayoutMode.entries.firstOrNull { it.name == galleryPrefs.getString(LAYOUT_MODE_KEY, null) }
                ?: MediaLayoutMode.GRID,
        )
    }
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
    // Tapping the Vault tab again on Media goes to the top of the grid or list
    // (iOS #275). Only the half on screen is composed, so only it hears this.
    LaunchedEffect(isGrid) {
        com.nostrvault.ui.navigation.TabReselect.of(com.nostrvault.ui.navigation.Screen.Dashboard).collect {
            if (isGrid) gridState.animateScrollToItem(0) else listState.animateScrollToItem(0)
        }
    }
    var contextMenuTarget by remember { mutableStateOf<Int?>(null) }
    var pendingDelete by remember { mutableStateOf<Pair<BlossomMediaItem, DeleteScope>?>(null) }
    // Report Media / Block User from the long-press menu: the author's pubkey.
    var reportTarget by remember { mutableStateOf<String?>(null) }
    var blockTarget by remember { mutableStateOf<String?>(null) }
    val colors = LocalNostrVaultColors.current
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
    val sortPrefs = galleryPrefs
    var sortOption by remember {
        mutableStateOf(MediaSortOption.fromKey(sortPrefs.getString(MediaSortOption.STORAGE_KEY, null)))
    }

    val filteredItems = remember(mediaItems, typeSelection, sortOption) {
        sortOption.sorted(mediaItems.filter { MediaTypeSelection.matches(typeSelection, it) })
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
                    // Leading: the Vault tab's mode pill. The type filters that
                    // sat here fold into a menu on the right (iOS mediaTypeMenu).
                    modePill()

                    Spacer(Modifier.weight(1f))

                    // Type + sort + layout toggle + upload. In the Vault tab,
                    // Messages leads, as on every Vault mode.
                    GlassPill {
                        LocalVaultMessages.current?.let { messages ->
                            VaultMessagesButton(messages)
                            Box(
                                Modifier
                                    .padding(horizontal = 2.dp)
                                    .width(1.dp)
                                    .height(20.dp)
                                    .background(Color.White.copy(alpha = 0.18f)),
                            )
                        }
                        MediaGalleryToolbarActions(
                            typeSelection = typeSelection,
                            onTypeTap = onTypeTap,
                            sortOption = sortOption,
                            onSort = { option ->
                                sortOption = option
                                sortPrefs.edit().putString(MediaSortOption.STORAGE_KEY, option.key).apply()
                            },
                            layoutMode = layoutMode,
                            onToggleLayout = {
                                layoutMode = if (layoutMode == MediaLayoutMode.GRID)
                                    MediaLayoutMode.LIST else MediaLayoutMode.GRID
                                galleryPrefs.edit().putString(LAYOUT_MODE_KEY, layoutMode.name).apply()
                            },
                            isUploading = isUploading,
                            onPickPhotos = {
                                mediaPickerLauncher.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                )
                            },
                            onPickVideos = {
                                mediaPickerLauncher.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly),
                                )
                            },
                            onPickFiles = { filePickerLauncher.launch(arrayOf("image/*", "video/*")) },
                            onMagicPaste = { viewModel.pasteFromClipboard(context) },
                        )
                    }
                }
            }
        },
        floatingActionButton = {
            // The FAB folds with the bars, following the finger.
            val folded by rememberChromeFolded()
            Box(Modifier.chromeFab().blockedWhen(folded)) {
                Surface(
                    onClick = onOpenDashboard,
                    modifier = Modifier
                        .floatingRowButton()
                        .tutorialAnchor(TutorialContent.VAULT_RELAY),
                    color = dashboardColor,
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
                            imageVector = NostrVaultIcons.TabVault,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Vault",
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
            val emptyState = mediaEmptyState(total = mediaItems.size, shown = filteredItems.size, isLoading = isLoading)
            if (emptyState != null) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = padding.calculateTopPadding()),
                ) {
                    MediaEmptyStateView(emptyState)
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
                                key = gridHeaderKey(section.title),
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
                                    MediaGalleryBridge.currentItems = withNoteIds(filteredItems, noteIdByHash)
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
                // The grid's headings stay pinned at the top, as iOS's
                // LazyVGrid(pinnedViews: .sectionHeaders) and the list do.
                PinnedGridHeader(
                    state = gridState,
                    sections = sections,
                    top = padding.calculateTopPadding() + 2.dp,
                )
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
                                    MediaGalleryBridge.currentItems = withNoteIds(filteredItems, noteIdByHash)
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
        val postCount = remember(item.sha256, scope) {
            if (scope == DeleteScope.EVERYWHERE) mediaActions.postsUsing(item.sha256) else 0
        }
        fun confirm(deletePosts: Boolean) {
            pendingDelete = null
            when (scope) {
                DeleteScope.MIRRORS -> mediaActions.deleteFromMirrors(item) { viewModel.refresh() }
                DeleteScope.EVERYWHERE -> mediaActions.deleteEverywhere(item, deletePosts = deletePosts) { viewModel.refresh() }
            }
        }
        DeleteBlobConfirmDialog(
            scope = scope,
            postCount = postCount,
            onConfirm = { confirm(deletePosts = false) },
            onConfirmWithPosts = { confirm(deletePosts = true) },
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
