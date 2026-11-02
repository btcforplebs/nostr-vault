package com.nostrvault.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.BookmarkService
import com.nostrvault.ui.notification.LocalNotificationManager
import com.nostrvault.ui.notification.PillTone
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface BookmarkEntryPoint {
    fun bookmarkService(): BookmarkService
}

/** The app's [BookmarkService], for composables outside a view model. */
@Composable
fun rememberBookmarkService(): BookmarkService {
    val context = LocalContext.current
    return remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, BookmarkEntryPoint::class.java).bookmarkService()
    }
}

/**
 * "Bookmark" / "Remove bookmark" for a note's ••• menu: one `e` (or `a` for an article) entry on the account's
 * kind 10003, through [BookmarkService.toggle]. Null for a read-only sign-in, which can't sign the list. A repost
 * acts on the original it shows. iOS `BookmarkMenuItem`.
 */
@Composable
fun rememberBookmarkAction(note: FeedNote): NoteAction? {
    val service = rememberBookmarkService()
    val canSign = rememberCanSign()
    val list by service.list.collectAsState()
    val saving by service.saving.collectAsState()
    val lane = LocalNotificationManager.current
    LaunchedEffect(Unit) { service.refreshInBackground() }
    if (!canSign) return null
    val entry = service.entry(note.effectiveEventId, note.effectiveAuthor, note.effectiveKind, note.tags)
    if (entry in saving) return null
    val marked = service.isBookmarked(list, entry)
    return NoteAction(
        icon = if (marked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder,
        label = if (marked) "Remove bookmark" else "Bookmark",
    ) {
        service.toggle(entry) { message ->
            if (message.startsWith("Bookmark not")) lane.showFeedback(message, null, PillTone.ERROR)
            else lane.showFeedback(message, Icons.Filled.Bookmark)
        }
    }
}
