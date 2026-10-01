package com.nostrvault.ui.screens.feed

import android.content.Context
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalContext
import coil.imageLoader
import coil.request.ImageRequest
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.feedImageModel
import com.nostrvault.ui.components.isVideoUrl
import com.nostrvault.ui.components.prefetchAvatar
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch

/** One image a feed row is about to draw, described the way the row requests it. */
internal sealed interface FeedPrefetchItem {
    val key: String

    /** A note photo; [size] matches the row's own `ImageRequest.size`. */
    data class Media(val model: String, val size: Int) : FeedPrefetchItem {
        override val key get() = "$size:$model"
    }

    data class Avatar(val url: String) : FeedPrefetchItem {
        override val key get() = "avatar:$url"
    }
}

/**
 * Starts loading the photos and avatars of the next [ROWS_AHEAD] rows while the
 * current ones are on screen, so a row arrives already drawn instead of
 * assembling itself as it scrolls in. iOS parity: `FeedView.prefetchAhead`.
 *
 * Each image is requested exactly as its row will request it (same model and
 * decode size, same avatar loader), so the row's own request is a memory-cache
 * hit. Only [MAX_CONCURRENT] prefetches run at once: Coil has no request
 * priority, so this cap is what keeps the rows on screen ahead of the queue.
 * Videos without a poster image are skipped; their frames have a lane of their
 * own and on-screen rows need it more.
 *
 * [itemsForRow] returns the images row `index` will draw, or empty.
 */
@Composable
internal fun FeedPrefetchEffect(
    listState: LazyListState,
    itemsForRow: (Int) -> List<FeedPrefetchItem>,
) {
    val context = LocalContext.current.applicationContext
    val currentItemsForRow by rememberUpdatedState(itemsForRow)
    // URLs already asked for this screen session; bounded so a long scroll
    // cannot grow it without limit. Re-asking is only wasted work, not wrong.
    val requested = remember { LinkedHashSet<String>() }

    LaunchedEffect(listState) {
        val queue = Channel<FeedPrefetchItem>(Channel.UNLIMITED)
        coroutineScope {
            repeat(MAX_CONCURRENT) {
                launch {
                    for (item in queue) runCatching { load(context, item) }
                }
            }
            snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index }
                .filterNotNull()
                .distinctUntilChanged()
                .collect { last ->
                    for (row in last + 1..last + ROWS_AHEAD) {
                        for (item in currentItemsForRow(row)) {
                            if (!requested.add(item.key)) continue
                            if (requested.size > MAX_REMEMBERED) requested.remove(requested.first())
                            queue.trySend(item)
                        }
                    }
                }
        }
    }
}

private suspend fun load(context: Context, item: FeedPrefetchItem) {
    when (item) {
        is FeedPrefetchItem.Avatar -> prefetchAvatar(context, item.url)
        is FeedPrefetchItem.Media -> context.imageLoader.execute(
            ImageRequest.Builder(context).data(item.model).size(item.size).build()
        )
    }
}

/**
 * The images a flat-feed row for [note] draws: its author's and reposter's
 * avatars, and its photos at the size the full card (800) or the compact
 * card's single thumbnail (128) decodes them.
 */
internal fun prefetchItemsFor(
    note: FeedNote,
    profiles: Map<String, FeedProfile>,
    compact: Boolean,
): List<FeedPrefetchItem> = buildList {
    listOfNotNull(note.pubkey, note.repostedBy).forEach { pubkey ->
        profiles[pubkey]?.pictureURL?.takeIf { it.isNotBlank() }?.let { add(FeedPrefetchItem.Avatar(it)) }
    }
    val urls = if (compact) note.mediaURLs.take(1) else note.mediaURLs
    for (url in urls) {
        val model = feedImageModel(note.tags, url)
        if (isVideoUrl(model)) continue
        add(FeedPrefetchItem.Media(model, if (compact) 128 else 800))
    }
}

/** A threaded row: each line's avatar and its first photo's thumbnail (root 160, reply 112). */
internal fun prefetchItemsForThread(
    entries: List<Pair<FeedNote, Boolean>>,
    profiles: Map<String, FeedProfile>,
): List<FeedPrefetchItem> = buildList {
    for ((note, isRoot) in entries) {
        profiles[note.pubkey]?.pictureURL?.takeIf { it.isNotBlank() }?.let { add(FeedPrefetchItem.Avatar(it)) }
        val url = note.mediaURLs.firstOrNull() ?: continue
        if (isVideoUrl(url)) continue
        add(FeedPrefetchItem.Media(url, if (isRoot) 160 else 112))
    }
}

private const val ROWS_AHEAD = 8
private const val MAX_CONCURRENT = 3
private const val MAX_REMEMBERED = 2_000

/**
 * Asks for the next page while the list is near its end, and again after each
 * page lands if it is still near the end.
 *
 * Keyed on [shouldLoadMore] alone, a page that added fewer rows than the
 * threshold left it true, the effect never fired again, and the feed stalled
 * at the bottom. A page that added nothing leaves [size] unchanged, so this
 * stops there instead of re-asking forever; scrolling away and back retries.
 */
@Composable
internal fun LoadMoreEffect(
    shouldLoadMore: Boolean,
    isLoadingMore: Boolean,
    size: Int,
    onLoadMore: () -> Unit,
) {
    var sizeAtLastLoad by remember { mutableIntStateOf(-1) }
    LaunchedEffect(shouldLoadMore, isLoadingMore, size) {
        if (!shouldLoadMore) {
            sizeAtLastLoad = -1
        } else if (!isLoadingMore && size > 0 && size != sizeAtLastLoad) {
            sizeAtLastLoad = size
            onLoadMore()
        }
    }
}
