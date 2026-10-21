package com.nostrvault.ui.components

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow

/**
 * Keeps a newest-first list at its top when newer rows arrive there.
 *
 * A keyed LazyColumn anchors the row that was first on screen, so rows
 * prepended above it land out of sight and the list seems to open in the
 * middle (SwiftUI's ScrollView doesn't anchor, so iOS shows them). When the
 * first key changes while you are (or just were) at the top, this scrolls
 * back to row 0. The Feed tab does the same inline (FeedScreen's reveal).
 *
 * [keys] reads the keys the list renders, in order.
 */
@Composable
fun RevealNewestEffect(listState: LazyListState, keys: () -> List<Any>) {
    val currentKeys by rememberUpdatedState(keys)
    LaunchedEffect(listState) {
        var previousFirst: Any? = null
        var wasAtTop = true
        snapshotFlow {
            val atTop = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 50
            currentKeys() to atTop
        }.collect { (list, atTop) ->
            if ((wasAtTop || atTop) && isPrepend(previousFirst, list)) {
                // requestScrollToItem wins over the next layout's key
                // anchoring; animateScrollToItem could see index 0 and stop.
                listState.requestScrollToItem(0)
            }
            previousFirst = list.firstOrNull()
            wasAtTop = atTop
        }
    }
}

/**
 * Rows came in above the old first one: the first key changed and the old
 * first row is still in the list (a reload that replaces it is not a prepend).
 */
internal fun isPrepend(previousFirst: Any?, keys: List<Any>): Boolean {
    val first = keys.firstOrNull() ?: return false
    return previousFirst != null && first != previousFirst && previousFirst in keys
}
