package com.nostrvault.ui.screens.vault

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.BookmarkList
import com.nostrvault.service.BookmarkService
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class BookmarksViewModel @Inject constructor(
    val service: BookmarkService,
    private val nostrService: NostrService,
    configStore: ConfigStore,
) : ViewModel() {
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val account: StateFlow<String> = configStore.activeAccountHexPubkey
    fun fetchProfiles(pubkeys: List<String>) { if (pubkeys.isNotEmpty()) nostrService.fetchMissingProfiles(pubkeys) }
}

/**
 * Vault > Bookmarks, a Vault mode beside Zaps (Logen 2026-11-03): the active account's kind 10003, newest first.
 * Notes and articles bookmarked in any app; the private ones (encrypted in the list) are shown read-only.
 * Bookmark sets (30003) are not in v1. Twin of iOS `BookmarksView`.
 */
@Composable
fun BookmarksContent(
    padding: PaddingValues,
    listState: androidx.compose.foundation.lazy.LazyListState,
    onOpenNote: (String) -> Unit,
    onOpenArticle: (String) -> Unit,
    onOpenProfile: (String) -> Unit,
    viewModel: BookmarksViewModel = hiltViewModel(),
) {
    val list by viewModel.service.list.collectAsState()
    val account by viewModel.account.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    var privateEntries by remember { mutableStateOf<List<BookmarkList.Entry>>(emptyList()) }
    var events by remember { mutableStateOf<Map<BookmarkList.Entry, NostrEvent>>(emptyMap()) }
    var loading by remember { mutableStateOf(true) }
    val publicEntries = remember(list) { BookmarkList.entries(list?.tags.orEmpty()) }

    LaunchedEffect(account) {
        loading = true
        events = emptyMap()
        viewModel.service.refresh(force = true)
        privateEntries = viewModel.service.privateEntries()
    }
    LaunchedEffect(list?.id, privateEntries) {
        loading = true
        val wanted = (publicEntries + privateEntries).filter { it !in events }
        val found = viewModel.service.events(wanted)
        events = events + found
        viewModel.fetchProfiles(found.values.map { it.pubkey }.distinct())
        loading = false
    }

    LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 88.dp,
                start = 12.dp,
                end = 12.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (loading && events.isEmpty()) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Reading your bookmarks…", color = SecondaryText)
                    }
                }
            } else if (publicEntries.isEmpty() && privateEntries.isEmpty()) {
                item { Text("No bookmarks yet. Use Bookmark in a note's ••• menu to keep it here.", color = SecondaryText) }
            }
            items(publicEntries, key = { "pub-${it.tag[1]}" }) { entry ->
                BookmarkRow(entry, events[entry], profiles, loading, onOpenNote, onOpenArticle, onOpenProfile)
            }
            if (privateEntries.isNotEmpty()) {
                item {
                    Column(Modifier.padding(top = 12.dp, bottom = 4.dp)) {
                        Text("Private bookmarks", color = PrimaryText, fontSize = 15.sp)
                        Text(
                            "Only you can see these. They are shown here as they are; change them in the app that made them.",
                            color = SecondaryText,
                            fontSize = 12.sp,
                        )
                    }
                }
                items(privateEntries, key = { "priv-${it.tag[1]}" }) { entry ->
                    BookmarkRow(entry, events[entry], profiles, loading, onOpenNote, onOpenArticle, onOpenProfile)
                }
            }
        }
}

@Composable
private fun BookmarkRow(
    entry: BookmarkList.Entry,
    event: NostrEvent?,
    profiles: Map<String, FeedProfile>,
    loading: Boolean,
    onOpenNote: (String) -> Unit,
    onOpenArticle: (String) -> Unit,
    onOpenProfile: (String) -> Unit,
) {
    if (event == null) {
        Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp)) {
                Text(if (loading) "Loading…" else "Not found on your relays", color = SecondaryText)
                Text(entry.tag[1], color = SecondaryText, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        return
    }
    val note = FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
    val isArticle = entry is BookmarkList.Entry.Address
    VaultNoteCard(
        note = note,
        profile = profiles[note.pubkey],
        profiles = profiles,
        onNoteClick = { if (isArticle) onOpenArticle(note.id) else onOpenNote(note.id) },
        onArticleClick = onOpenArticle,
        onProfileClick = onOpenProfile,
    )
}
