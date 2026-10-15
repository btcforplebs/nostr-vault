package com.nostrvault.ui.screens.vault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.VaultSearchLogic
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService

/**
 * Opens the Vault's search, provided by the Vault tab so its toolbars can show
 * the magnifying glass (iOS `searchToggleButton`). Null: no search here.
 */
val LocalOpenVaultSearch = staticCompositionLocalOf<(() -> Unit)?> { null }

/**
 * The Vault while its search is open (iOS VaultView with `isSearchActive`): the
 * bar that grew out of the icon, and the results in place of the list. Back, or
 * the bar's ✕, folds it away.
 */
@Composable
internal fun VaultSearchScreen(
    nostrService: NostrService,
    feedService: FeedService,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onClose: () -> Unit,
    bottomInset: PaddingValues = PaddingValues(bottom = 120.dp),
) {
    val scope = rememberCoroutineScope()
    val model = remember(nostrService, feedService) { VaultSearchModel(scope, nostrService, feedService) }
    DisposableEffect(model) { onDispose { model.cancel() } }
    var text by rememberSaveable { mutableStateOf("") }
    val status by model.status.collectAsState()
    val results by model.results.collectAsState()
    val resultsQuery by model.resultsQuery.collectAsState()
    val profiles by nostrService.profiles.collectAsState()
    // Back from a note or profile the results opened: the field kept its text,
    // so search it again rather than show an empty list under it.
    LaunchedEffect(model) { if (text.isNotEmpty()) model.search(text, now = true) }
    var closing by remember { mutableStateOf(false) }
    val close = {
        model.cancel()
        onClose()
    }
    BackHandler(enabled = !closing) { closing = true; close() }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        VaultSearchBar(
            text = text,
            onTextChange = {
                text = it
                model.search(it)
            },
            onSubmit = { model.search(text, now = true) },
            onClose = close,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        VaultSearchResults(
            status = status,
            results = results,
            resultsQuery = resultsQuery,
            profiles = profiles,
            onProfile = onProfileClick,
            onNote = { note: FeedNote ->
                if (note.kind == VaultSearchLogic.ARTICLE_KIND) onArticleClick(note.id) else onNoteClick(note.id)
            },
            contentPadding = bottomInset,
        )
    }
}
