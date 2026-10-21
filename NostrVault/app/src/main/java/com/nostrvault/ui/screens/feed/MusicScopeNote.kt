package com.nostrvault.ui.screens.feed

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import com.nostrvault.ui.components.FilterNote
import com.nostrvault.ui.components.rememberFilterNoteState
import com.nostrvault.ui.screens.music.MusicFeedState
import com.nostrvault.ui.screens.music.MusicScope
import com.nostrvault.ui.screens.music.TrendingWindow
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop

/** The setting half of the Music toolbar note: "Trending this week", the artist, or "Artists you follow". */
internal fun musicScopeNoteSetting(scope: MusicScope, window: TrendingWindow): String = when (scope) {
    MusicScope.Trending -> "Trending ${window.title.lowercase()}"
    is MusicScope.Artist -> scope.artist.name
    MusicScope.Following -> "Artists you follow"
}

/**
 * Shows the toolbar's note when Music's scope or trending window changes:
 * "Music · Trending this week", "Music · <artist>", "Music · Artists you
 * follow". Only on change, not on arrival. iOS `MusicToolbarNoteObserver`.
 */
@Composable
internal fun MusicScopeNoteObserver() {
    val note = rememberFilterNoteState()
    LaunchedEffect(Unit) {
        combine(MusicFeedState.scope, MusicFeedState.trendingWindow) { scope, window -> scope to window }
            .distinctUntilChanged()
            .drop(1)
            .collect { (scope, window) ->
                val icon = when (scope) {
                    MusicScope.Trending -> NostrVaultIcons.Popular
                    is MusicScope.Artist -> NostrVaultIcons.AccountCircle
                    MusicScope.Following -> NostrVaultIcons.People
                }
                note.show(FilterNote.setting(icon, "Music", musicScopeNoteSetting(scope, window)))
            }
    }
}
