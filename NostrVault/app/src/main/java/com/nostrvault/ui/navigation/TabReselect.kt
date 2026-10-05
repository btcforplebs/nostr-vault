package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.filter

/**
 * Tapping the Relay or Media tab while it is showing: the tab's screen scrolls
 * its list to the top, as the Feed tab does (iOS #275 `RelayScrollToTop` /
 * `MediaScrollToTop`). The Feed keeps its own signal in FeedService because
 * its reselect can also refresh.
 */
object TabReselect {
    private val _requests = MutableSharedFlow<Screen>(extraBufferCapacity = 1)
    val requests: SharedFlow<Screen> = _requests.asSharedFlow()

    fun request(screen: Screen) {
        _requests.tryEmit(screen)
    }

    /** Reselects of one tab. */
    fun of(screen: Screen) = requests.filter { it == screen }
}
