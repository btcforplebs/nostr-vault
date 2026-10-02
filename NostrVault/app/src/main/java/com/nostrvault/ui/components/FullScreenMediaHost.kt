package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Routes full-screen media viewing requests to a host composed at the activity
 * root (above the NavHost). The viewer must live in the activity window — not a
 * Dialog — because Picture-in-Picture only captures the activity's own window;
 * a Dialog-hosted video would vanish the moment PiP starts.
 */
object FullScreenMediaRouter {

    /**
     * [origin] names the row of media the tap came from (see [mediaZoomSource]);
     * with it the viewer zooms out of the tapped photo and back into it. Null
     * opens with a fade.
     */
    data class Request(val urls: List<String>, val initialIndex: Int, val origin: Long? = null)

    private val _request = MutableStateFlow<Request?>(null)
    val request = _request.asStateFlow()

    /** The viewer's current item as a source key, while a viewer opened from a source is up. */
    private val _position = MutableStateFlow<MediaSourceKey?>(null)
    val position = _position.asStateFlow()

    /** The source the viewer is drawing its image over; that source hides itself. */
    private val _hiddenSource = MutableStateFlow<MediaSourceKey?>(null)
    val hiddenSource = _hiddenSource.asStateFlow()

    fun open(urls: List<String>, initialIndex: Int, origin: Long? = null) {
        if (urls.isEmpty()) return
        _request.value = Request(urls, initialIndex, origin)
        _position.value = origin?.let { MediaSourceKey(it, initialIndex) }
    }

    /** Called by the viewer as it pages, so a carousel underneath can follow. */
    internal fun setPage(page: Int) {
        val origin = _request.value?.origin ?: return
        _position.value = MediaSourceKey(origin, page)
    }

    internal fun setHiddenSource(key: MediaSourceKey?) {
        _hiddenSource.value = key
    }

    /** Removes the viewer outright. The viewer's own close animation calls this when it lands. */
    fun dismiss() {
        _request.value = null
        _position.value = null
        _hiddenSource.value = null
    }
}

/** Composed once in MainActivity above the NavHost; shows the pager when requested. */
@Composable
fun FullScreenMediaHost() {
    val request by FullScreenMediaRouter.request.collectAsState()
    request?.let {
        // Keyed so a new request starts a fresh open animation.
        androidx.compose.runtime.key(it) {
            FullScreenMediaPager(
                urls = it.urls,
                initialIndex = it.initialIndex,
                origin = it.origin,
                onDismiss = FullScreenMediaRouter::dismiss,
            )
        }
    }
}
