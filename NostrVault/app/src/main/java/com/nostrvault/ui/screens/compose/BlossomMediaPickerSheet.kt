package com.nostrvault.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import com.nostrvault.ui.notification.LocalNotificationManager
import com.nostrvault.ui.theme.NostrVaultIcons
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun BlossomMediaPickerSheet(
    onDismiss: () -> Unit,
    onSelect: (BlossomMediaItem) -> Unit,
    /** Shared with the live stream chat, so the loader comes from the caller. */
    loadItems: suspend () -> List<BlossomMediaItem>,
) {
    val context = LocalContext.current
    val lane = LocalNotificationManager.current
    val colors = LocalNostrVaultColors.current
    var blossomMedia by remember { mutableStateOf<List<BlossomMediaItem>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    // The Media tab's type filter, shared both ways as on iOS.
    val (typeSelection, onTypeTap) = rememberMediaTypeSelection()
    // The Media tab's sort, so the headings match what that tab shows (iOS
    // reads the same MediaSortOption setting).
    // Changing it here changes the tab too, both ways, as iOS's shared @AppStorage.
    val sortPrefs = remember { context.getSharedPreferences(MEDIA_GALLERY_PREFS, Context.MODE_PRIVATE) }
    var sortOption by remember {
        mutableStateOf(MediaSortOption.fromKey(sortPrefs.getString(MediaSortOption.STORAGE_KEY, null)))
    }
    var showSortMenu by remember { mutableStateOf(false) }
    val shownMedia = remember(blossomMedia, typeSelection, sortOption) {
        sortOption.sorted(blossomMedia.filter { MediaTypeSelection.matches(typeSelection, it) })
    }
    val sections = remember(shownMedia, sortOption) { MediaDateGrouping.sections(shownMedia, sortOption) }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            try {
                // Load blossom media from local relay
                val items = loadItems()
                withContext(Dispatchers.Main) {
                    blossomMedia = items
                    isLoading = false
                }
            } catch (e: Exception) {
                Log.e("BlossomPicker", "Failed to load media", e)
                withContext(Dispatchers.Main) {
                    isLoading = false
                }
            }
        }
    }

    // Opens nearly full height; swipe down still closes it.
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = WindowBackground
    ) {
        // The grid runs 8 from the edges; the title and filter keep 16.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 16.dp)
        ) {
            Text(
                text = "Pick from Blossom",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = PrimaryText,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp)
            )
            // The Media tab's filter and sort (iOS: type row + sort menu).
            // Audio has no chip of its own, as on iOS; it shows under All.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 16.dp, end = 8.dp, bottom = 12.dp),
            ) {
                Box(modifier = Modifier.weight(1f)) {
                    MediaTypeFilterPill(
                        selection = typeSelection,
                        onSelect = onTypeTap,
                        filters = listOf(
                            MediaTypeFilter.ALL,
                            MediaTypeFilter.PHOTO,
                            MediaTypeFilter.VIDEO,
                            MediaTypeFilter.GIF,
                        ),
                    )
                }
                Box {
                    IconButton(onClick = { showSortMenu = true }, modifier = Modifier.size(44.dp)) {
                        Icon(
                            imageVector = Icons.Filled.SwapVert,
                            contentDescription = "Sort by: ${sortOption.label}",
                            tint = colors.primary,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                    DropdownMenu(expanded = showSortMenu, onDismissRequest = { showSortMenu = false }) {
                        for (option in MediaSortOption.entries) {
                            DropdownMenuItem(
                                text = { Text(option.label) },
                                leadingIcon = {
                                    if (option == sortOption) {
                                        Icon(
                                            Icons.Filled.Check,
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
            }

            if (isLoading) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else if (shownMedia.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (blossomMedia.isEmpty()) "No media on Blossom" else "Nothing of this type",
                        color = SecondaryText,
                        fontSize = 14.sp
                    )
                }
            } else {
                // The Media tab's date headings, pinned while their run
                // scrolls, with iOS's 6 between cells, 8 between rows and 8 at
                // the edges. A grid has no pinned headers in this Compose
                // version, so rows of three go in a list.
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(start = 8.dp, end = 8.dp, bottom = 8.dp),
                    modifier = Modifier.heightIn(max = 400.dp)
                ) {
                    for (section in sections) {
                        if (section.title.isNotEmpty()) {
                            stickyHeader(key = "header:${section.title}") { MediaSectionHeader(section.title) }
                        }
                        items(section.items.chunked(3), key = { row -> row.first().sha256 }) { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                row.forEach { item ->
                                    Box(
                                        modifier = Modifier
                                            .weight(1f)
                                            .aspectRatio(1f)
                                            .clip(RoundedCornerShape(8.dp))
                                            .combinedClickable(
                                                onClick = { onSelect(item) },
                                                onLongClick = {
                                                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                                    clipboard.setPrimaryClip(ClipData.newPlainText("Blossom URL", item.displayUrl))
                                                    lane.showFeedback("Link copied", NostrVaultIcons.LinkIcon)
                                                }
                                            )
                                    ) {
                                        if (item.isAudio) {
                                            AudioThumbnail(iconSize = 28.dp)
                                        } else {
                                            AsyncImage(
                                                model = item.localFile ?: item.displayUrl,
                                                contentDescription = null,
                                                modifier = Modifier.fillMaxSize(),
                                                contentScale = ContentScale.Crop
                                            )
                                        }

                                        if (item.isVideo) {
                                            Icon(
                                                imageVector = Icons.Default.PlayArrow,
                                                contentDescription = "Video",
                                                tint = Color.White,
                                                modifier = Modifier
                                                    .align(Alignment.Center)
                                                    .size(32.dp)
                                            )
                                        }
                                    }
                                }
                                // A short last row keeps its cells the same size.
                                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}
